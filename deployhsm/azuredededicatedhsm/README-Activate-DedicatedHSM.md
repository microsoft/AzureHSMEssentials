# Activate Azure Dedicated HSM (Thales Luna HSM A790)

This guide covers the **minimum steps** to activate an Azure Dedicated HSM, register a client VM, and verify connectivity. No STC (Secure Trusted Channel) setup is required -- NTLS provides the encrypted channel.

> **Prerequisites:**
>
> - Azure Dedicated HSM deployed (see [README.md](README.md))
> - Admin VM deployed (RHEL 8) with network access to the HSM subnet
> - Thales Luna HSM Client V10.9.2 downloaded from the [Thales Support Portal](https://supportportal.thalesgroup.com/csm?id=kb_article_view&sysparm_article=KB0030276)
> - Package: `610-000397-018_SW_Linux_Luna_Client_V10.9.2_RevA.tar`

---

## Platform Reference

| Resource            | Value                           | Description                                         |
| ------------------- | ------------------------------- | --------------------------------------------------- |
| Admin VM            | `dhsm-admin-vm`               | RHEL 8 VM in default subnet                         |
| Admin VM User       | `dhsmVMAdmin`                 | VM login username                                   |
| Admin VM Public IP  | *(from deployment output)*    | SSH access                                          |
| Admin VM Private IP | `10.3.0.4`                    | Used for client host-IP mapping                     |
| HSM Private IP      | `10.3.1.4`                    | Thales Luna HSM in delegated hsmSubnet              |
| HSM Login           | `tenantadmin` / `PASSWORD`  | Default credentials (password reset on first login) |
| Luna Client Path    | `/usr/safenet/lunaclient`     | Installed by Luna Client installer                  |
| Luna Binaries       | `/usr/safenet/lunaclient/bin` | vtl, lunacm, ckdemo, etc.                           |

---

## Quick Path: Which Steps Do I Need?

| Scenario                                                                                      | Steps                                                     |
| --------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| **Fresh HSM + fresh VM** (first time)                                                   | All steps: Phase 1 > 2 > 3 > 4 (Step 12 after Phase 3)    |
| **Existing HSM + new VM** (redeployed Admin VM, HSM already initialized with partition) | Phase 1 > 3 > 4 (skip Phase 2; CO/CU already initialized) |

---

## Phase 1: Install Luna Client on the Admin VM

Run all commands on the **Admin VM** via SSH.

```bash
# SSH to Admin VM
ssh dhsmVMAdmin@<ADMIN-VM-PUBLIC-IP>
```

### Step 1: Copy the Luna Client package to the VM

From your **local machine**:

```powershell
scp 610-000397-018_SW_Linux_Luna_Client_V10.9.2_RevA.tar dhsmVMAdmin@<ADMIN-VM-PUBLIC-IP>:/tmp/
```

### Step 2: Install prerequisites and extract

```bash
sudo yum install -y libnsl
cd /tmp
tar -xvf 610-000397-018_SW_Linux_Luna_Client_V10.9.2_RevA.tar
cd LunaClient_10.9.2-282_Linux/64/
```

### Step 3: Install the Luna Client

```bash
sudo ./install.sh
```

Accept defaults. When prompted for components, install at minimum: **Luna Network HSM**, **Luna Cryptoki (PKCS#11)**.

### Step 4: Verify installation

```bash
ls /usr/safenet/lunaclient/bin/vtl
sudo /usr/safenet/lunaclient/bin/vtl verify
```

Expected: `Error: There are no registered servers` -- this is correct for a fresh install.

### Step 5: Set up PATH and library paths

```bash
# Add Luna bin to PATH
echo 'export PATH=/usr/safenet/lunaclient/bin:$PATH' >> ~/.bashrc

# Add Luna libraries to dynamic linker
echo "/usr/safenet/lunaclient/lib" | sudo tee /etc/ld.so.conf.d/lunaclient.conf
sudo ldconfig

# Create symlink for PKCS#11 compatibility
sudo ln -sf /usr/safenet/lunaclient/lib/libCryptoki2_64.so /usr/safenet/lunaclient/lib/libCryptoki2.so
sudo ldconfig

# Apply PATH change
source ~/.bashrc
```

### Step 6: Verify libraries

```bash
ldconfig -p | grep Cryptoki
```

Expected: `libCryptoki2_64.so` entries pointing to `/usr/safenet/lunaclient/lib/`.

---

## Phase 2: Initialize the HSM (first time only)

> **Skip this phase** if the HSM is already initialized with a partition (e.g., redeployed Admin VM).

### Step 7: SSH to the HSM appliance

```bash
ssh tenantadmin@10.3.1.4
```

Default password is `PASSWORD`. You will be forced to change it on first login.

### Step 8: Verify HSM status

```
lunash:> hsm show
```

Confirm the HSM is operational (will show `ZEROIZED` state before initialization).

### Step 9: Initialize the HSM

```
lunash:> hsm init -label <HSM-NAME> -defaultdomain
```

Use the HSM name from your deployment (e.g., `dhsmwllcixidr7mqk`). Set and record the **SO (Security Officer) password** when prompted.

### Step 10: Login as HSM Admin

```
lunash:> hsm login
```

Enter the SO password you just created.

### Step 11: Create an application partition

```
lunash:> partition create -partition <PARTITION-NAME>
```

Example: `partition create -partition prod-adcs`. Type `proceed` when prompted. Set and record the **partition password**.

### Step 12: Initialize partition roles (PO and CO)

After creating the partition in LunaSH (Step 11), the PKCS#11 roles (Partition Owner, Crypto Officer, Crypto User) are **not yet initialized** on the client side. You must bootstrap them from `lunacm` on the Admin VM before any keys can be created.

> **Prerequisites:** Phase 3 (NTLS connectivity) must be complete and `vtl verify` must show the partition.

Exit LunaSH if you are still connected:

```
lunash:> exit
```

On the **Admin VM**, launch `lunacm` with sudo:

```bash
sudo /usr/safenet/lunaclient/bin/lunacm
```

#### 12a. Initialize the partition (bootstrap PO)

This maps the client-side PKCS#11 token to the HSM partition and initializes the **Partition Owner (PO)** role:

```
lunacm:> partition init -label prod-adcs -password <partition-password> -domain <cloning-domain>
```

- `-label` must match the partition name from Step 11.
- `-password` is the partition password you set in Step 11.
- `-domain` is the cloning domain you set in Step 11 (e.g., `adcsdomain`). Use `-defaultdomain` instead if you did not set a custom domain.

Expected output: `Command Result : No Error`

#### 12b. Log in as Partition Owner

```
lunacm:> role login -name po
```

Enter the **partition password** from Step 11. Expected output: `Command Result : No Error`

#### 12c. Initialize the Crypto Officer

```
lunacm:> role init -name co
```

Set and record the **CO password** when prompted. The CO can create and manage keys inside the partition -- this role is required for ADCS key generation via the SafeNet KSP.

#### 12d. Activate the CO password

After initial creation, the CO password is in an "expired" state on PW-auth partitions. You must change it before the CO can initialize the CU role:

```
lunacm:> role changepw -name co
```

Enter the current CO password, then set a new password (or re-enter the same one).

#### 12e. Initialize the Crypto User (CU)

Log out PO/CO and log back in as CO (with the activated password), then initialize CU:

```
lunacm:> role logout
lunacm:> role login -name co
lunacm:> role init -name cu
```

Set and record the **CU password** when prompted. The CU has limited permissions (use keys but not create/delete them). For ADCS, the CO role handles key creation during `Install-AdcsCertificationAuthority`, while the CU can be used for runtime signing operations.

> **Note:** On PW-auth partitions, `role createchallenge` is not supported. Initialize the CU directly with `role init -name cu` while logged in as CO.

Exit lunacm:

```
lunacm:> exit
```

> **Why `partition init` is needed:** LunaSH `partition create` creates the partition on the HSM appliance, but does not initialize the client-side PKCS#11 roles. Running `partition init` from `lunacm` bootstraps the PO role so you can then initialize CO and CU. Without this step, `role login -name po` will fail with "po is not yet initialized".

### Step 13: Regenerate the HSM server certificate

SSH back to the HSM:

```bash
ssh tenantadmin@10.3.1.4
```

```
lunash:> sysconf regenCert
```

Type `proceed` when prompted.

### Step 14: Bind NTLS and restart

```
lunash:> ntls bind eth0
lunash:> ntls show
lunash:> service restart ntls
```

Verify `ntls show` displays the HSM IP bound to `eth0`.

### Step 15: Exit LunaSH

```
lunash:> exit
```

---

## Phase 3: Register the Client VM with the HSM

### Step 16: Create a client certificate on the VM

> **Warning:** Do NOT use `vtl createCert` -- on Luna Client v10.9.2 it encrypts the private key with AES-256-CBC by default (no way to disable), which breaks NTLS authentication. Use `openssl genrsa` + `openssl req` instead.

```bash
# Generate an RSA private key in PKCS#1 format (BEGIN RSA PRIVATE KEY)
sudo openssl genrsa -out /usr/safenet/lunaclient/cert/client/dhsm-admin-vmKey.pem 2048

# Generate a self-signed certificate from that key
sudo openssl req -new -x509 -days 3650 \
  -key /usr/safenet/lunaclient/cert/client/dhsm-admin-vmKey.pem \
  -out /usr/safenet/lunaclient/cert/client/dhsm-admin-vm.pem \
  -subj "/CN=dhsm-admin-vm"

# Set correct permissions
sudo chmod 400 /usr/safenet/lunaclient/cert/client/dhsm-admin-vmKey.pem
sudo chown root:hsmusers /usr/safenet/lunaclient/cert/client/dhsm-admin-vmKey.pem
sudo chmod 444 /usr/safenet/lunaclient/cert/client/dhsm-admin-vm.pem
sudo chown root:hsmusers /usr/safenet/lunaclient/cert/client/dhsm-admin-vm.pem
```

Verify the key is PKCS#1 format:

```bash
sudo head -1 /usr/safenet/lunaclient/cert/client/dhsm-admin-vmKey.pem
# Must show: -----BEGIN RSA PRIVATE KEY-----
# If it shows BEGIN PRIVATE KEY (PKCS#8), Luna NTLS will fail silently.
```

### Step 17: Fix the HSM clock (if needed)

Azure Dedicated HSM appliances often default to EDT (UTC-4) instead of UTC, which can cause client certificates to appear "not yet valid" during NTLS handshake. Check and fix before proceeding:

```bash
ssh tenantadmin@10.3.1.4
```

In LunaSH:

```
lunash:> status date
```

If the displayed time is behind the current UTC time, set it to UTC:

```
lunash:> sysconf time HH:MM YYYYMMDD
lunash:> service restart ntls
lunash:> exit
```

Replace `HH:MM` and `YYYYMMDD` with the current UTC time and date.

### Step 18: Download the HSM server certificate

```bash
cd /usr/safenet/lunaclient/bin
sudo scp tenantadmin@10.3.1.4:server.pem .
ls server.pem
```

### Step 19: Register the HSM server in the Luna client

```bash
sudo ./vtl addServer -n 10.3.1.4 -c ./server.pem
```

Expected: `New server 10.3.1.4 successfully added to server list.`

### Step 20: Copy the client certificate to the HSM

```bash
sudo scp /usr/safenet/lunaclient/cert/client/dhsm-admin-vm.pem tenantadmin@10.3.1.4:
```

### Step 21: Register the client on the HSM

SSH to the HSM:

```bash
ssh tenantadmin@10.3.1.4
```

Run in LunaSH:

```
lunash:> client register -client dhsm-admin-vm -hostname dhsm-admin-vm
lunash:> client list
```

Expected: `registered client 1: dhsm-admin-vm`

### Step 22: Map the client's private IP

```
lunash:> client hostip map -client dhsm-admin-vm -ip <ADMIN-VM-PRIVATE-IP>
```

> **Important:** Use the Admin VM's actual **private IP** in the HSM VNet (default subnet), not the public IP. Verify with `hostname -I` on the VM -- do not assume it matches the original deployment (DHCP may assign a different address after redeployment).

### Step 23: Assign the partition to the client

```
lunash:> client assignPartition -client dhsm-admin-vm -partition <PARTITION-NAME>
```

Example: `client assignPartition -client dhsm-admin-vm -partition prod-adcs`

### Step 24: Restart NTLS and exit

```
lunash:> service restart ntls
lunash:> exit
```

---

## Phase 4: Verify Connectivity

Back on the **Admin VM**:

### Step 25: Verify the HSM connection

```bash
cd /usr/safenet/lunaclient/bin
sudo ./vtl verify
```

Expected output:

```
The following Luna SA Slots/Partitions were found:

Slot    Serial #                Label
====    ================        =====
   0       <serial>             <partition-name>
```

**If you see a slot -- activation is complete.** The HSM is connected and the partition is usable.

### Step 26: Confirm server and slot details

```bash
sudo ./vtl listServers
sudo ./vtl listSlots
```

---

## Troubleshooting

| Symptom                                           | Cause                                           | Fix                                                                              |
| ------------------------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------- |
| `vtl verify` shows no slots                     | Client not registered or partition not assigned | Re-run Steps 21-24 on the HSM                                                    |
| `vtl verify` shows no slots (errno=104)         | HSM clock behind cert Not Before (time skew)    | Fix HSM clock with `sysconf time` (Step 17), restart NTLS                      |
| `vtl verify` shows connection refused           | NTLS not running or not bound                   | SSH to HSM:`ntls show` > `ntls bind eth0` > `service restart ntls`         |
| `vtl addServer` fails                           | Wrong server.pem or HSM cert was regenerated    | Re-download server.pem (Step 18)                                                 |
| `client register` can't find cert               | SCP'd cert not in staging area                  | Use `-hostname` flag (not `-ip`): `client register -c name -hostname name` |
| `vtl createCert` key unusable                   | v10.9.2 encrypts keys by default (AES-256-CBC)  | Use `openssl genrsa` + `openssl req` instead (Step 16)                       |
| SSH to 10.3.1.4 refused                           | ExpressRoute gateway not ready or NSG blocking  | Verify gateway is provisioned and subnet delegation is correct                   |
| `client register` fails with "already exists"   | Previous client registration still present      | `client delete -client dhsm-admin-vm` then re-register                         |
| Wrong VM private IP mapped                        | DHCP assigned different IP after redeployment   | Check `hostname -I` on VM, remap with `client hostip`                        |
| `client hostip map` fails with "already mapped" | Previous mapping still present                  | `client hostip unmap -client dhsm-admin-vm -ip <old-ip>` then re-map           |

---

## Re-Register a New Admin VM (Existing HSM)

If the HSM is already initialized with a partition but you redeployed the Admin VM:

1. Complete **Phase 1** (install Luna Client on new VM)
2. On the HSM, clean up the old client registration:
   ```
   ssh tenantadmin@10.3.1.4
   lunash:> client delete -client dhsm-admin-vm
   lunash:> sysconf regenCert
   lunash:> service restart ntls
   lunash:> exit
   ```
3. Complete **Phase 3** (register the new VM as a client)
4. Complete **Phase 4** (verify connectivity)
