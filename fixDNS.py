# pip install azure-identity azure-mgmt-network azure-mgmt-resource aiohttp

import asyncio
from azure.identity.aio import DefaultAzureCredential
from azure.mgmt.network.aio import NetworkManagementClient

SUBSCRIPTION_ID = "<your-subscription-id>"
RESOURCE_GROUP = "<your-rg-name>"

# 🔹 groupId → DNS Zone ID mapping
DNS_ZONE_MAP = {
    "blob": "/subscriptions/.../privatelink.blob.core.windows.net",
    "file": "/subscriptions/.../privatelink.file.core.windows.net",
    "queue": "/subscriptions/.../privatelink.queue.core.windows.net",
    "table": "/subscriptions/.../privatelink.table.core.windows.net",
    "dfs": "/subscriptions/.../privatelink.dfs.core.windows.net",

    "vault": "/subscriptions/.../privatelink.vaultcore.azure.net",
    "sqlServer": "/subscriptions/.../privatelink.database.windows.net",

    "Sql": "/subscriptions/.../privatelink.documents.azure.com",
    "MongoDB": "/subscriptions/.../privatelink.mongo.cosmos.azure.com",
    "Cassandra": "/subscriptions/.../privatelink.cassandra.cosmos.azure.com",
    "Gremlin": "/subscriptions/.../privatelink.gremlin.cosmos.azure.com",
    "Table": "/subscriptions/.../privatelink.table.cosmos.azure.com",

    "namespace": "/subscriptions/.../privatelink.servicebus.windows.net",
    "eventHub": "/subscriptions/.../privatelink.servicebus.windows.net",
    "topic": "/subscriptions/.../privatelink.eventgrid.azure.net",
    "registry": "/subscriptions/.../privatelink.azurecr.io",
    "sites": "/subscriptions/.../privatelink.azurewebsites.net"
}

SEM = asyncio.Semaphore(10)  # throttle control


async def process_private_endpoint(client, pe):
    async with SEM:
        pe_name = pe.name
        pe_id = pe.id

        print(f"Processing: {pe_name}")

        # 🔹 Get existing DNS zone groups
        existing_zones = set()

        try:
            zone_groups = client.private_dns_zone_groups.list(
                RESOURCE_GROUP, pe_name
            )

            async for zg in zone_groups:
                for config in zg.private_dns_zone_configs:
                    existing_zones.add(config.private_dns_zone_id.split("/")[-1])

        except Exception:
            pass  # No zone groups yet

        # 🔹 Process groupIds
        for conn in pe.private_link_service_connections:
            for group_id in conn.group_ids:

                if group_id not in DNS_ZONE_MAP:
                    print(f"[{pe_name}] Unknown groupId: {group_id}")
                    continue

                zone_id = DNS_ZONE_MAP[group_id]
                zone_name = zone_id.split("/")[-1]

                if zone_name in existing_zones:
                    continue

                print(f"[{pe_name}] Attaching {zone_name}")

                await attach_dns_zone(client, pe_name, zone_name, zone_id)


async def attach_dns_zone(client, pe_name, zone_name, zone_id, retries=3):
    for attempt in range(retries):
        try:
            await client.private_dns_zone_groups.begin_create_or_update(
                RESOURCE_GROUP,
                pe_name,
                "default",
                {
                    "private_dns_zone_configs": [
                        {
                            "name": zone_name,
                            "private_dns_zone_id": zone_id
                        }
                    ]
                }
            )
            return
        except Exception as e:
            if attempt == retries - 1:
                print(f"Failed for {pe_name}: {e}")
            await asyncio.sleep(2 * (attempt + 1))


async def main():
    credential = DefaultAzureCredential()
    client = NetworkManagementClient(credential, SUBSCRIPTION_ID)

    private_endpoints = []

    async for pe in client.private_endpoints.list(RESOURCE_GROUP):
        private_endpoints.append(pe)

    tasks = [
        process_private_endpoint(client, pe)
        for pe in private_endpoints
    ]

    await asyncio.gather(*tasks)

    await credential.close()
    await client.close()


if __name__ == "__main__":
    asyncio.run(main())
