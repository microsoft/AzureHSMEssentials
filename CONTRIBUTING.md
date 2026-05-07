# Contributing

Thank you for your interest in contributing to **Azure HSM Essentials**. This project is a collection of ARM templates, deployment scripts, migration toolkits, and validation utilities that help customers deploy and operate Azure HSM services (Key Vault Premium, Managed HSM, Cloud HSM, Dedicated HSM, and Payment HSM).

We welcome bug reports, fixes, new scenarios, and documentation improvements.

## Contributor License Agreement (CLA)

This project welcomes contributions and suggestions. Most contributions require you to agree to a Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us the rights to use your contribution.

For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide a CLA and decorate the PR appropriately (e.g. status check, comment). Simply follow the instructions provided by the bot. You will only need to do this once across all repositories using our CLA.

## Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## How to contribute

### Reporting bugs

Open a GitHub issue and include:

- The HSM platform involved (Key Vault, Managed HSM, Cloud HSM, Dedicated HSM, Payment HSM)
- The script or template name
- Azure region
- The exact command you ran (with subscription IDs and tenant IDs redacted)
- The full error output (with secrets redacted)
- Expected vs. actual behavior

### Suggesting enhancements

Open a GitHub issue describing:

- The scenario you want to enable
- Why it's valuable (which customer pain point it addresses)
- Any prior art or links to relevant docs

### Submitting pull requests

1. Fork the repo and create a topic branch from `main`.
2. Keep PRs focused -- one scenario or one fix per PR.
3. Test your changes against a real Azure environment when possible.
4. Update the relevant `README-*.md` if you change template parameters or script behavior.
5. Do not commit secrets, subscription IDs, tenant IDs, certificates, private keys, or customer-specific data. The `.gitignore` blocks the common patterns; double-check before pushing.
6. Sign your commits if your environment supports it.
7. Open the PR against `main`. Fill out the PR template.

### Style guidelines

- **PowerShell**: PascalCase for functions, approved verbs (`Get-`, `Set-`, `Invoke-`), parameter blocks with types, no aliases in committed code.
- **ARM templates**: parameterize anything environment-specific (region, names, IP ranges). Provide a sample `*-parameters.json` next to each template.
- **Bash**: `set -euo pipefail` at the top; quote all variable expansions.
- **No em dashes** (--) in code or comments; use `--` instead.
- Markdown headings: sentence case, one `#` H1 per file.

## Security

If you find a security vulnerability, **do not open a public issue**. Follow the private disclosure process in [SECURITY.md](SECURITY.md).

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft trademarks or logos is subject to and must follow [Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/legal/intellectualproperty/trademarks/usage/general). Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos is subject to those third-party's policies.
