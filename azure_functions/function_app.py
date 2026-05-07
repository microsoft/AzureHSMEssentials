import azure.functions as func
import json
import logging

app = func.FunctionApp()

# Operations of interest for Cloud HSM audit monitoring
MONITORED_OPERATIONS = {
    "CN_CREATE_USER",
    "CN_DELETE_USER",
    "CN_INSERT_MASKED_OBJECT_USER",
    "CN_EXTRACT_MASKED_OBJECT_USER",
    "CN_GENERATE_KEY",
    "CN_GENERATE_KEY_PAIR",
    "CN_LOGIN",
    "CN_LOGOUT",
    "CN_AUTHORIZE_SESSION",
    "CN_FIND_OBJECTS_USING_COUNT",
    "CN_TOMBSTONE_OBJECT",
}


@app.function_name(name="CloudHsmAuditMonitor")
@app.event_hub_message_trigger(
    arg_name="events",
    event_hub_name="cloudhsm-logs",
    connection="EventHubConnection",
    consumer_group="hsm-scenario-builder",
    cardinality="many",
    data_type="string",
)
def cloudhsm_audit_monitor(events: list[func.EventHubEvent]):
    """
    Processes Cloud HSM diagnostic log batches from Event Hub.
    Filters for monitored operations and logs them with structured detail.
    """
    for event in events:
        try:
            body = event.get_body().decode("utf-8")
            payload = json.loads(body)

            records = payload.get("records", [])
            if not records:
                continue

            for record in records:
                op_name = record.get("operationName", "")

                if op_name not in MONITORED_OPERATIONS:
                    continue

                # Extract audit fields
                timestamp = record.get("time", "")
                caller_ip = record.get("callerIpAddress", "unknown")
                result = record.get("resultType", "")
                resource_id = record.get("resourceId", "")
                opcode = record.get("properties", {}).get("opcode", "")
                session_handle = record.get("properties", {}).get("session_handle", "")
                cluster_id = record.get("properties", {}).get("cluster_id", "")

                log_entry = {
                    "operation": op_name,
                    "timestamp": timestamp,
                    "callerIp": caller_ip,
                    "result": result,
                    "opcode": opcode,
                    "sessionHandle": session_handle,
                    "clusterId": cluster_id,
                    "resourceId": resource_id,
                }

                # Log level based on operation type
                if op_name in ("CN_DELETE_USER", "CN_TOMBSTONE_OBJECT"):
                    logging.critical(
                        "[HSM AUDIT] DESTRUCTIVE: %s from %s | %s",
                        op_name, caller_ip, json.dumps(log_entry),
                    )
                elif op_name in ("CN_CREATE_USER", "CN_GENERATE_KEY", "CN_GENERATE_KEY_PAIR"):
                    logging.warning(
                        "[HSM AUDIT] %s from %s | %s",
                        op_name, caller_ip, json.dumps(log_entry),
                    )
                elif op_name in ("CN_INSERT_MASKED_OBJECT_USER", "CN_EXTRACT_MASKED_OBJECT_USER"):
                    logging.warning(
                        "[HSM AUDIT] KEY MOVEMENT: %s from %s | %s",
                        op_name, caller_ip, json.dumps(log_entry),
                    )
                else:
                    logging.info(
                        "[HSM AUDIT] %s from %s | %s",
                        op_name, caller_ip, json.dumps(log_entry),
                    )

        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            logging.error("[HSM AUDIT] Failed to parse event: %s", str(e))
        except Exception as e:
            logging.error("[HSM AUDIT] Unexpected error processing event: %s", str(e))
