# Preparing GLPI 11 for the monitor

One-time setup in GLPI, done by an administrator. It takes about ten minutes. The goal is that the agents can **create tickets and nothing else that matters**: a dedicated API client, a dedicated technical user and a least-privilege profile.

> Menu labels below are from the English UI of GLPI 11.0. In Spanish they are the obvious translations (*Configuración > General > API*, *Perfiles*, etc.).

## 1. Enable the legacy REST API

**Setup > General > API**

| Setting | Value | Why |
|---|---|---|
| Enable Legacy REST API | **Yes** | The agents use `apirest.php`, which is simple to call from PowerShell and curl. |
| Enable login with credentials | **No** | No passwords travel over the API. |
| Enable login with external token | **Yes** | The agents log in with a user token. |

GLPI 11 also ships a new high-level API (`/api.php`, OAuth2). The monitor does not use it yet; see *Roadmap* in the README.

## 2. Create an API client with an App-Token

Same page, **API clients** section → **Add**.

- **Name:** `GLPI proactive monitor`
- **Active:** Yes
- **IPv4 address range:** the range of your workstations and servers (for example `10.0.0.1` – `10.0.255.254`). Requests from anywhere else are refused even with a valid token.
- **Application token (app_token):** tick **Regenerate** and save. Copy the value: it is the `App-Token` the agents send.

## 3. Create the least-privilege profile

**Administration > Profiles > Add**, name `API Monitor`, interface **Standard**. Then set only these rights and leave everything else empty:

| Tab / object | Rights | What it allows |
|---|---|---|
| Assistance > **Tickets** | *Create* + *See my tickets* | Open tickets and read the ones it opened (needed to check if a ticket is still open before creating another). |
| Assistance > **Followups** | *See public ones* + *Add (requester)* | Add the "still failing" and "recovered" followups. |
| Management > **Documents** | *See all* + *Create* | Upload the diagnostic file and link it to the ticket. |
| Assets > **Computers** | *See all* | Find the computer by name to link it to the ticket. |

Two traps found while deploying it on a real GLPI 11.0.13:

- The profile **must use the standard interface**. With the simplified interface the *Assets* and *Management* tabs are not shown at all.
- The read right is the **See all** column. **Read notes** is a different right (only the notes of the object) and does not let the agent find the computer: the agent then reports `ERROR_RIGHT_MISSING`.

That is the full list. In the lab (`lab/setup-lab.sh`) these exact rights are written as bitmasks (`ticket=5`, `followup=5`, `document=5`, `computer=1`) and every API call of the monitor was tested with them.

What this profile **cannot** do: see other people's tickets, close or delete tickets, change assets, read users, or log into the web interface in any useful way.

## 4. Create the technical user

**Administration > Users > Add**

- **Login:** `svc-glpi-monitor`
- **Password:** a long random one (it is never used, the agents use the token).
- **Authorizations** tab: profile `API Monitor` on your root entity, recursive (or only on the entity the monitored computers belong to).
- **Remote access keys > API token:** tick **Regenerate** and save. Copy the value: it is the `User-Token`.

## 5. Optional: route the tickets

The agents can fill these fields on every ticket (all optional, by ID):

| Agent setting (Windows / Linux) | GLPI field | Suggested value |
|---|---|---|
| `Glpi.GroupsIdAssign` / `GROUPS_ID_ASSIGN` | Assigned group | Your *Sistemas N2* / *Infrastructure* group |
| `Glpi.ItilCategoriesId` / `ITILCATEGORIES_ID` | Category | A new *Monitoring* category |
| `Glpi.RequestTypesId` / `REQUESTTYPES_ID` | Request source | A new *Automatic monitoring* source, so you can report on proactive vs. reactive tickets |
| `Glpi.EntitiesId` / `ENTITIES_ID` | Entity | When you manage several sites or customers |

The ID of any object is the number at the end of its URL in GLPI (`...form.php?id=7`).

## 6. Check it

From any machine in the allowed IP range:

```bash
curl -s https://glpi.example.local/apirest.php/initSession \
  -H "App-Token: <app token>" -H "Authorization: user_token <user token>"
```

A `{"session_token": "..."}` answer means GLPI is ready. Then run the agent with `-TestConnection` (Windows) or `--test` (Linux).
