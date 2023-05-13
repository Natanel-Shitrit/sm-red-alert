#include <sourcemod>
#include <sdktools>
#include <multicolors>
#include <ripext>

#pragma newdecls required
#pragma semicolon 1

#define PREFIX " \x04"... PREFIX_NO_COLOR ..."\x01"
#define PREFIX_NO_COLOR "[RED-ALERT]"

#define DATABASE_TABLE "red_alert_player_areas"

enum
{
    ALERT_HUD = (1 << 0), 
    ALERT_CHAT = (1 << 1), 
    ALERT_SOUND = (1 << 2)
}

// Database connection
Database g_Database;

// websocket for alerts
WebSocket g_AlertsWS;

// ConVars
ConVar g_AlertAPIDomain;
ConVar g_APIRetryInterval;
ConVar g_AlertMethod;
ConVar g_SoundPath;

// Users Menu(s)
Menu g_AreaChooserMenu;

// Users areas
ArrayList g_UsersAreas[MAXPLAYERS + 1];

// Alert sound to emit.
char g_AlertSound[PLATFORM_MAX_PATH];

public Plugin myinfo = 
{
    name = "Red-Alert", 
    author = "Natanel 'LuqS'", 
    description = "Alerts players about red-alerts in their area.", 
    version = "2.0.0", 
    url = "https://steamcommunity.com/id/luqsgood || Discord: LuqS#6505"
};

/****************************
        Startup Setup
*****************************/

public void OnPluginStart()
{
    SetupMenus();
    SetupTranslations();
    SetupDatabase();
    SetupConVars();
    SetupCommands();
    SetupAlertsAPI();
}

void SetupMenus()
{
    LogMessage("Building Menus...");

    // TODO: Optionally, load 'areas.json' from API.
    JSONObject areas_json;
    if (!(areas_json = JSONObject_LoadDataFile("data/red-alert/areas.json")))
    {
        SetFailState("Failed to open 'areas.json', please add it to 'sourcemod/data/red-alert' folder");
    }
    
    g_AreaChooserMenu = new Menu(Handler_DistricChooserMenu, MenuAction_Select | MenuAction_DisplayItem);
    g_AreaChooserMenu.SetTitle("%s Choose areas that will trigger alerts:\n ", PREFIX_NO_COLOR);
    
    char current_key[64], current_area_id[6];
    JSONObjectKeys areas_keys = areas_json.Keys();
    while (areas_keys.ReadKey(current_key, sizeof(current_key)))
    {
        IntToString(areas_json.GetInt(current_key), current_area_id, sizeof(current_area_id));
        g_AreaChooserMenu.AddItem(current_area_id, current_key);
    }
    
    delete areas_keys;
    delete areas_json;
}

void SetupTranslations()
{
    LogMessage("Loading Translations...");
    LoadTranslations("red-alert.phrases");
}

void SetupDatabase()
{
    LogMessage("Initializing Database...");
    Database.Connect(Database_OnConnection, "red-alert");
}

void SetupConVars()
{
    LogMessage("Creating ConVars...");
    g_AlertAPIDomain = CreateConVar(
        .name = "red_alert_api_domain",
        .defaultValue = "",
        .description = "The domain of the Alert-API domain."
    );
    g_APIRetryInterval = CreateConVar(
        .name = "red_alert_api_retry_interval",
        .defaultValue = "30.0",
        .description = "Time in seconds to wait before retrying to establish a connection to the Alert-API.",
        .hasMin = true
    );
    g_AlertMethod = CreateConVar(
        .name = "red_alert_alert_method",
        .defaultValue = "5",
        .description = "Alert methods: 1 - HUD, 2 - Chat, 4 - Sound, Example: 1 + 4 = 5 will show both HUD and play a sound",
        .hasMin = true
    );
    g_SoundPath = CreateConVar(
        "red_alert_sound_path",
        "sound/ui/arm_bomb.wav",
        "Sound for the alert if sound is enabled in 'red_alert_alert_method' (add with 'sound/')"
    );
    
    LogMessage("Loading ConVar Values...");
    AutoExecConfig();

    LogMessage("Adding ConVar Hooks...");
    g_SoundPath.GetString(g_AlertSound, sizeof(g_AlertSound));
    g_SoundPath.AddChangeHook(ChangeHook_HandleAlertSound);
}

void SetupCommands()
{
    LogMessage("Registering Commands...");
    RegConsoleCmd("sm_redalerts", Command_RedAlerts);
    RegConsoleCmd("sm_ra", Command_RedAlerts);
}

void SetupAlertsAPI()
{
    LogMessage("Connecting to alerts API...");
    char alert_api_domain[256];
    g_AlertAPIDomain.GetString(alert_api_domain, sizeof(alert_api_domain));
    
    if (!alert_api_domain[0])
    {
        LogMessage("No Alert-API domain, skipping...");
        return;
    }

    char websocket_url[256];
    Format(websocket_url, sizeof(websocket_url), "ws://%s/alerts", alert_api_domain);

    g_AlertsWS = new WebSocket(websocket_url);
    g_AlertsWS.SetReadCallback(WebSocket_JSON, WS_OnAlert);
    g_AlertsWS.SetConnectCallback(WS_OnConnected);
    g_AlertsWS.SetDisconnectCallback(WS_OnDisconnected);

    if (!g_AlertsWS.Connect())
    {
        LogMessage("Connection to alerts API failed!");
        WS_OnDisconnected(g_AlertsWS, 0);
    }
}

/******************************
        Server Forawrds
*******************************/

public void OnMapStart()
{
    LogMessage("Processing alert sound...");

    if (g_AlertSound[0])
    {
        AddFileToDownloadsTable(g_AlertSound);
        PrecacheSound(g_AlertSound[6], true);
    }
}

/******************************
        Client Forawrds
*******************************/

public void OnClientAuthorized(int client, const char[] auth)
{
    if (IsFakeClient(client))
    {
        return;
    }
    
    g_UsersAreas[client] = new ArrayList();
    
    int account_id;
    if (!(account_id = GetSteamAccountID(client)))
    {
        return;
    }
    
    char query[256];
    g_Database.Format(query, sizeof(query), 
        "SELECT \
            `area_id` \
        FROM \
            "...DATABASE_TABLE..." \
        WHERE \
            `account_id` = %d", 
        account_id
    );
    
    g_Database.Query(Database_ClientDataReceived, query, GetClientUserId(client));
}

public void OnClientDisconnect(int client)
{
    if (!g_UsersAreas[client])
    {
        return;
    }
    
    int account_id = GetSteamAccountID(client);
    if (!account_id)
    {
        delete g_UsersAreas[client];
        return;
    }
    
    Transaction txn = new Transaction();
    
    char query[256];
    g_Database.Format(query, sizeof(query), 
        "DELETE FROM \
            "...DATABASE_TABLE..." \
        WHERE \
            `account_id` = %d", 
        account_id
    );
    
    txn.AddQuery(query);
    
    for (int current_area_id; current_area_id < g_UsersAreas[client].Length; current_area_id++)
    {
        g_Database.Format(query, sizeof(query), 
            "INSERT INTO "...DATABASE_TABLE..." \
            ( \
                `account_id`, \
                `area_id` \
            ) \
            VALUES \
            (\
                 %d, \
                 %d \
            )", 
            account_id, 
            g_UsersAreas[client].Get(current_area_id)
        );
        
        txn.AddQuery(query);
    }
    
    g_Database.Execute(txn, .onError = Database_ClientDataTxnFalied, .data = account_id);
    
    delete g_UsersAreas[client];
}

void Database_ClientDataTxnFalied(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    ThrowError("Database Transaction failed (account-id = %d), Error: %s (query %d)", data, error, failIndex + 1);
}

/************************
        WebSocket
*************************/

void WS_OnAlert(WebSocket ws, JSON json, any data)
{
    JSONObject alerts = view_as<JSONObject>(json);
    JSONObjectKeys alert_areas = alerts.Keys();

    int active_alerts_count = 0;
    ArrayList areas_with_alerts = new ArrayList();
    char area_num[11], alerts_message[512], current_area_name[64];
    while (alert_areas.ReadKey(area_num, sizeof(area_num)))
    {
        areas_with_alerts.Push(StringToInt(area_num));
        JSONArray district_names = view_as<JSONArray>(alerts.Get(area_num));

        if (active_alerts_count)
        {
            StrCat(alerts_message, sizeof(alerts_message), ", ");
        }

        // Construct alert message.
        for (int currnt_area_index; currnt_area_index < district_names.Length; currnt_area_index++)
        {
            // Count active alerts.
            active_alerts_count++;

            // Get district name.
            district_names.GetString(
                currnt_area_index,
                current_area_name,
                sizeof(current_area_name)
            );

            // Add a comma if it's not the fist index, to prevent adding comma in the start of the message.
            if (currnt_area_index)
            {
                StrCat(alerts_message, sizeof(alerts_message), ", ");
            }

            // Add area name to message.
            StrCat(alerts_message, sizeof(alerts_message), current_area_name);
        }

        // Don't leak handles.
        delete district_names;
    }

    PrintToServer(alerts_message);

    // GO TO MAMAD NOW!
    AlertClientsInActiveAreas(alerts_message, areas_with_alerts, active_alerts_count);

    // Don't leak handles.
    delete areas_with_alerts;
    delete alert_areas;
    delete json;
}

void WS_OnConnected(WebSocket ws, any data)
{
    LogMessage("Conneced to alerts API!");
}

void WS_OnDisconnected(WebSocket ws, any data)
{
    LogMessage("Alerts API connection dropped!");
    delete ws;
    WS_Retry();
}

void WS_Retry()
{
    LogMessage("Retrying connection in %.1f seconds...", g_APIRetryInterval.FloatValue);
    CreateTimer(g_APIRetryInterval.FloatValue, WS_Reconnect);
}

Action WS_Reconnect(Handle timer)
{
    SetupAlertsAPI();
    return Plugin_Handled;
}

void AlertClientsInActiveAreas(const char[] alerts_message, ArrayList areas, int active_alerts_count)
{
    for (int current_client = 1; current_client <= MaxClients; current_client++)
    {
        if (IsClientAuthorized(current_client) && !IsFakeClient(current_client) && IsClientInAlertArea(current_client, areas))
        {
            if (g_AlertMethod.IntValue & ALERT_HUD)
            {
                ShowPanel2(current_client, 5, "%t", "HUD Alert Message", active_alerts_count, alerts_message);
            }
            
            if (g_AlertMethod.IntValue & ALERT_CHAT)
            {
                CPrintToChat(current_client, "%t", "Chat Alert Message", active_alerts_count, alerts_message);
            }
            
            if ((g_AlertMethod.IntValue & ALERT_SOUND) && g_AlertSound[0])
            {
                ClientCommand(current_client, "play %s", g_AlertSound[6]);
            }
        }
    }
}

bool IsClientInAlertArea(int client, ArrayList alert_areas)
{
    for (int current_alert_area; current_alert_area < alert_areas.Length; current_alert_area++)
    {
        if (g_UsersAreas[client].FindValue(alert_areas.Get(current_alert_area)) != -1)
        {
            return true;
        }
    }
    
    return false;
}

void ShowPanel2(int client, int duration, const char[] format, any ...)
{
    char formatted_message[1024];
    VFormat(formatted_message, sizeof(formatted_message), format, 4);
    
    Event show_survival_respawn_status = CreateEvent("show_survival_respawn_status");
    if (show_survival_respawn_status != null)
    {
        show_survival_respawn_status.SetString("loc_token", formatted_message);
        show_survival_respawn_status.SetInt("duration", duration);
        show_survival_respawn_status.SetInt("userid", -1);
        
        show_survival_respawn_status.FireToClient(client);
    }

    delete show_survival_respawn_status;
}

/***********************
        Commands
************************/

public Action Command_RedAlerts(int client, int argc)
{
    if (client)
    {
        g_AreaChooserMenu.Display(client, MENU_TIME_FOREVER);
    }
    
    return Plugin_Handled;
}

/**********************
        Menus
***********************/

int Handler_DistricChooserMenu(Menu menu, MenuAction action, int client, int item_pos)
{
    char item_info[6], item_display[64];
    int area_id, area_alert_index;
    
    if (action == MenuAction_Select || action == MenuAction_DisplayItem)
    {
        menu.GetItem(item_pos, item_info, sizeof(item_info), _, item_display, sizeof(item_display));
        area_id = StringToInt(item_info);
        area_alert_index = g_UsersAreas[client].FindValue(area_id);
    }
    
    switch (action)
    {
        case MenuAction_Select:
        {
            bool area_ticked = area_alert_index != -1;
            
            if (area_ticked)
            {
                g_UsersAreas[client].Erase(area_alert_index);
            }
            else
            {
                g_UsersAreas[client].Push(area_id);
            }
            
            PrintToChat(client, "%s Area '\x10%s\x01' has been %s your alert list.", PREFIX, item_display, area_ticked ? "\x02removed\x01 from" : "\x04added\x01 to");
            
            g_AreaChooserMenu.DisplayAt(client, menu.Selection, MENU_TIME_FOREVER);
        }
        
        case MenuAction_DisplayItem:
        {
            Format(item_display, sizeof(item_display), "[%c] %s", area_alert_index != -1 ? 'V' : 'X', ReverseString(item_display, sizeof(item_display)));
            return RedrawMenuItem(item_display);
        }
    }
    
    return 0;
}

/* SOURCE: https://forums.alliedmods.net/showthread.php?t=178279 */
char[] ReverseString(char[] str, int maxlength)
{
    char buffer[512];
    
    for (int character = strlen(str); character >= 0; character--)
    {
        if (str[character] >= 0xD6 && str[character] <= 0xDE)
            continue;
        
        if (character > 0 && str[character - 1] >= 0xD7 && str[character - 1] <= 0xD9)
            Format(buffer, maxlength, "%s%c%c", buffer, str[character - 1], str[character]);
        else
            Format(buffer, maxlength, "%s%c", buffer, str[character]);
    }
    
    return buffer;
}

/***********************
        Database
************************/

void Database_OnConnection(Database db, const char[] error, any data)
{
    if (!(g_Database = db) || error[0])
    {
        SetFailState("Can't Connect To MySQL Database | Error: '%s'", error);
    }

    LogMessage("Database connection initialized!");
    LogMessage("Initializing tables...");

    g_Database.Query(Database_OnTableCreated, 
        "CREATE TABLE IF NOT EXISTS \
            `"...DATABASE_TABLE..."` \
        ( \
            `account_id` INT NOT NULL, \
            `area_id` INT NOT NULL \
        )"
    );
}

void Database_OnTableCreated(Database db, DBResultSet results, const char[] error, any data)
{
    if (!db || !results || error[0])
    {
        SetFailState("Can't create database table | Error: '%s'", error);
    }

    LogMessage("Database tables initialized!");
    LogMessage("Loading connected clients prefrences...");
    
    // Late-Load support.
    for (int current_client = 1; current_client <= MaxClients; current_client++)
    {
        if (IsClientInGame(current_client))
        {
            OnClientAuthorized(current_client, "");
        }
    }
}


void Database_ClientDataReceived(Database db, DBResultSet results, const char[] error, int userid)
{
    int client = GetClientOfUserId(userid);
    
    if (!db || !results || error[0])
    {
        ThrowError("Failed to retrive data for client: %d", client ? GetSteamAccountID(client) : -1);
    }
    
    // Client disconnected
    if (!client)
    {
        return;
    }
    
    // Fetch data
    while (results.FetchRow())
    {
        g_UsersAreas[client].Push(results.FetchInt(0));
    }
}

/**********************
        ConVars
***********************/

void ChangeHook_HandleAlertSound(ConVar convar, const char[] oldValue, const char[] newValue)
{
    strcopy(g_AlertSound, sizeof(g_AlertSound), newValue);
    OnMapStart();
}

/*************************
        Load Files
**************************/

JSONObject JSONObject_LoadDataFile(const char[] file_path)
{
    char full_path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, full_path, sizeof(full_path), file_path);
    return JSONObject.FromFile(full_path);
} 