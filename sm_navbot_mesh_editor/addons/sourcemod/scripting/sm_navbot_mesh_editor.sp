#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "0.19.0"
#define SIZE_STEP 10.0
#define CACHE_MATCH_MAX_DIST 150.0

enum struct PrereqCacheEntry
{
	float origin[3];
	char classname[64];
	char taskInfo[8];
	float halfX;
	float halfY;
	float heightZ;
	int team;
	int goalEntity;
}

// Confirmed via in-game sm_nav_scripting_list_conditions
#define TC_EXISTS 1
#define TC_ALIVE 2
#define TC_ENABLED 3
#define TC_LOCKED 4
#define TC_TEAM 5
#define TC_TOGGLE_STATE 6
#define TC_VISIBLE 8

#define TOGGLE_CONDITION_ENTITY_TOGGLE_STATE 6
// Confirmed via extension/bot/interfaces/movement.cpp comment: "Toggle state is at top when a
// func_door_rotating is open" -- so TS_AT_BOTTOM (1) is closed for this classname specifically.
#define TS_AT_BOTTOM 1

static const char g_DestroyEntityClassnames[][] = { "func_breakable" };
static const char g_UseEntityClassnames[][] = { "func_button", "func_door", "func_door_rotating", "prop_door_rotating", "prop_dynamic", "trigger_multiple" };

public Plugin myinfo =
{
	name = "ZPS Nav Prerequisite Menu",
	author = "Claude.ai guided by DNA.styx",
	description = "Menu-driven nav mesh prerequisite editing (create/mark/delete/size/origin)",
	version = PLUGIN_VERSION,
	url = ""
};

ConVar g_hCvarSvCheats;
ConVar g_hCvarNavEdit;
ConVar g_hCvarPrereqEdit;

// CNavPrerequisite has no getters (origin/bounds/selection). These are tracked assumptions only.
bool g_bMarked = false;
float g_HalfX = 0.0;
float g_HalfY = 0.0;
float g_HeightZ = 0.0;

int g_PendingEntity = -1;
char g_PendingTaskInfo[8];
char g_PendingTaskLabel[32];
char g_PendingEntityClassname[64];

// Classname of the goal entity actually confirmed for the CURRENT marked prereq, via our own
// Select/Yes flow. Empty if unknown (no NavBot getter exists to read this back from the engine).
char g_CurrentGoalClassname[64];
int g_CurrentGoalEntity = -1;
int g_CurrentTeam = -2;
float g_CurrentOrigin[3];

int g_PendingToggleType = -1;
char g_PendingToggleLabel[32];
int g_PendingToggleEntity = -1;
char g_PendingToggleValue[8];

// Session cache: our own record of prereqs we've set up, matched by nearest-origin on Mark since
// NavBot exposes no real ID or getters. Approximate, not authoritative -- see FindNearestCacheEntry.
ArrayList g_PrereqCache = null;
int g_ActiveCacheIndex = -1;

public void OnPluginStart()
{
	RegAdminCmd("sm_zps_navprereq_menu", Cmd_OpenMenu, ADMFLAG_ROOT, "Opens the nav prerequisite editing menu.");

	g_hCvarSvCheats = FindConVar("sv_cheats");
	g_hCvarNavEdit = FindConVar("sm_nav_edit");
	g_hCvarPrereqEdit = FindConVar("sm_nav_prerequisite_edit");

	g_PrereqCache = new ArrayList(sizeof(PrereqCacheEntry));
}

public Action Cmd_OpenMenu(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "Must be run in-game.");
		return Plugin_Handled;
	}

	ShowMainMenu(client);
	return Plugin_Handled;
}

int FindNearestCacheEntry(const float pos[3], float maxDist)
{
	int nearest = -1;
	float nearestDist = -1.0;

	for (int i = 0; i < g_PrereqCache.Length; i++)
	{
		PrereqCacheEntry entry;
		g_PrereqCache.GetArray(i, entry);

		float dist = GetVectorDistance(pos, entry.origin);

		if (dist > maxDist) { continue; }

		if (nearestDist < 0.0 || dist < nearestDist)
		{
			nearestDist = dist;
			nearest = i;
		}
	}

	return nearest;
}

void SyncActiveCacheEntry()
{
	if (g_ActiveCacheIndex == -1 || g_ActiveCacheIndex >= g_PrereqCache.Length) { return; }

	PrereqCacheEntry entry;
	entry.origin[0] = g_CurrentOrigin[0];
	entry.origin[1] = g_CurrentOrigin[1];
	entry.origin[2] = g_CurrentOrigin[2];
	strcopy(entry.classname, sizeof(entry.classname), g_CurrentGoalClassname);
	entry.goalEntity = g_CurrentGoalEntity;
	strcopy(entry.taskInfo, sizeof(entry.taskInfo), g_PendingTaskInfo);
	entry.halfX = g_HalfX;
	entry.halfY = g_HalfY;
	entry.heightZ = g_HeightZ;
	entry.team = g_CurrentTeam;
	g_PrereqCache.SetArray(g_ActiveCacheIndex, entry);
}

void ShowMainMenu(int client)
{
	if (g_hCvarSvCheats == null) { g_hCvarSvCheats = FindConVar("sv_cheats"); }
	if (g_hCvarNavEdit == null) { g_hCvarNavEdit = FindConVar("sm_nav_edit"); }
	if (g_hCvarPrereqEdit == null) { g_hCvarPrereqEdit = FindConVar("sm_nav_prerequisite_edit"); }

	bool editingEnabled = (g_hCvarNavEdit != null && g_hCvarNavEdit.BoolValue && g_hCvarPrereqEdit != null && g_hCvarPrereqEdit.BoolValue);

	Menu menu = new Menu(MenuHandler_Main);
	menu.SetTitle("Nav Prerequisite%s%s", g_bMarked ? " [MARKED]" : "", editingEnabled ? "" : " [EDITING OFF]");

	menu.AddItem("setup", "Server Setup");
	menu.AddItem("create", "Create", (!editingEnabled || g_bMarked) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("mark", g_bMarked ? "Unmark" : "Mark Nearest", editingEnabled ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("edit", "Edit", g_bMarked ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Main(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "setup"))
		{
			ShowSetupMenu(client);
		}
		else if (StrEqual(info, "create"))
		{
			ServerCommand("sm_nav_prereq_create");

			GetClientAbsOrigin(client, g_CurrentOrigin);
			g_CurrentGoalClassname[0] = '\0';
			g_CurrentGoalEntity = -1;
			g_PendingTaskInfo[0] = '0'; g_PendingTaskInfo[1] = '\0';
			g_HalfX = 32.0;
			g_HalfY = 32.0;
			g_HeightZ = 72.0;
			g_CurrentTeam = -2;

			PrereqCacheEntry entry;
			entry.origin[0] = g_CurrentOrigin[0];
			entry.origin[1] = g_CurrentOrigin[1];
			entry.origin[2] = g_CurrentOrigin[2];
			entry.halfX = g_HalfX;
			entry.halfY = g_HalfY;
			entry.heightZ = g_HeightZ;
			entry.team = g_CurrentTeam;
			entry.goalEntity = -1;
			strcopy(entry.taskInfo, sizeof(entry.taskInfo), "0");
			g_ActiveCacheIndex = g_PrereqCache.PushArray(entry);

			ReplyToCommand(client, "Created prerequisite at your position.");
			ShowMainMenu(client);
		}
		else if (StrEqual(info, "mark"))
		{
			ServerCommand("sm_nav_prereq_mark");
			g_bMarked = !g_bMarked;

			if (g_bMarked)
			{
				float pos[3];
				GetClientAbsOrigin(client, pos);
				int matched = FindNearestCacheEntry(pos, CACHE_MATCH_MAX_DIST);

				if (matched != -1)
				{
					PrereqCacheEntry entry;
					g_PrereqCache.GetArray(matched, entry);
					g_ActiveCacheIndex = matched;
					g_CurrentOrigin[0] = entry.origin[0];
					g_CurrentOrigin[1] = entry.origin[1];
					g_CurrentOrigin[2] = entry.origin[2];
					strcopy(g_CurrentGoalClassname, sizeof(g_CurrentGoalClassname), entry.classname);
					g_CurrentGoalEntity = entry.goalEntity;
					strcopy(g_PendingTaskInfo, sizeof(g_PendingTaskInfo), entry.taskInfo);
					g_HalfX = entry.halfX;
					g_HalfY = entry.halfY;
					g_HeightZ = entry.heightZ;
					g_CurrentTeam = entry.team;
					ReplyToCommand(client, "Marked. Matched cached record (approx, by nearest position) -- goal classname \"%s\", task %s.", entry.classname[0] ? entry.classname : "<unknown>", entry.taskInfo);
				}
				else
				{
					g_ActiveCacheIndex = -1;
					g_CurrentGoalClassname[0] = '\0';
					g_CurrentGoalEntity = -1;
					g_PendingTaskInfo[0] = '0'; g_PendingTaskInfo[1] = '\0';
					g_HalfX = 32.0;
					g_HalfY = 32.0;
					g_HeightZ = 72.0;
					g_CurrentTeam = -2;
					ReplyToCommand(client, "Marked. No cached record nearby -- tracking reset to unknown. Verify with sm_nav_prereq_draw_areas if not newly created.");
				}
			}
			else
			{
				g_ActiveCacheIndex = -1;
				ReplyToCommand(client, "Unmarked.");
			}

			ShowMainMenu(client);
		}
		else if (StrEqual(info, "edit"))
		{
			ShowEditMenu(client);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowSetupMenu(int client)
{
	if (g_hCvarSvCheats == null) { g_hCvarSvCheats = FindConVar("sv_cheats"); }
	if (g_hCvarNavEdit == null) { g_hCvarNavEdit = FindConVar("sm_nav_edit"); }
	if (g_hCvarPrereqEdit == null) { g_hCvarPrereqEdit = FindConVar("sm_nav_prerequisite_edit"); }

	Menu menu = new Menu(MenuHandler_Setup);
	menu.SetTitle("Server Setup");

	char cheatsLabel[32], navLabel[32], prereqLabel[32];
	Format(cheatsLabel, sizeof(cheatsLabel), "Cheats: %s", (g_hCvarSvCheats != null && g_hCvarSvCheats.BoolValue) ? "ON" : "OFF");
	Format(navLabel, sizeof(navLabel), "Nav Edit: %s", (g_hCvarNavEdit != null && g_hCvarNavEdit.BoolValue) ? "ON" : "OFF");
	Format(prereqLabel, sizeof(prereqLabel), "Prereq Edit: %s", (g_hCvarPrereqEdit != null && g_hCvarPrereqEdit.BoolValue) ? "ON" : "OFF");

	menu.AddItem("cheats", cheatsLabel);
	menu.AddItem("navedit", navLabel);
	menu.AddItem("prereqedit", prereqLabel);

	char markLabel[48];
	Format(markLabel, sizeof(markLabel), "Force Mark State: currently %s", g_bMarked ? "MARKED" : "UNMARKED");
	menu.AddItem("forcemark", markLabel);

	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Setup(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "cheats"))
		{
			if (g_hCvarSvCheats != null) { g_hCvarSvCheats.SetBool(!g_hCvarSvCheats.BoolValue); }
			ShowSetupMenu(client);
		}
		else if (StrEqual(info, "navedit"))
		{
			if (g_hCvarNavEdit != null) { g_hCvarNavEdit.SetBool(!g_hCvarNavEdit.BoolValue); }
			ShowSetupMenu(client);
		}
		else if (StrEqual(info, "prereqedit"))
		{
			if (g_hCvarPrereqEdit != null) { g_hCvarPrereqEdit.SetBool(!g_hCvarPrereqEdit.BoolValue); }
			ShowSetupMenu(client);
		}
		else if (StrEqual(info, "forcemark"))
		{
			g_bMarked = !g_bMarked;
			g_ActiveCacheIndex = -1;
			ReplyToCommand(client, "Tracker forced to %s (no command sent). Confirm against NavBot's own \"Selected Prerequisite\" on-screen text before relying on this.", g_bMarked ? "MARKED" : "UNMARKED");
			ShowSetupMenu(client);
		}
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowMainMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowEditMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Edit);
	menu.SetTitle("Edit");
	menu.AddItem("size", "Resize");
	menu.AddItem("origin", "Move to here");
	menu.AddItem("team", "Set Team");
	menu.AddItem("task", "Set Task");

	if (StrEqual(g_CurrentGoalClassname, "func_door_rotating", false))
	{
		menu.AddItem("watchdoor", "Watch Door (stop re-trigger when closed)");
	}
	else if (StrEqual(g_CurrentGoalClassname, "func_breakable", false))
	{
		menu.AddItem("notoggle", "Toggle Not Required", ITEMDRAW_DISABLED);
	}

	menu.AddItem("delete", "Delete");
	menu.AddItem("toggle", "Toggle Condition");
	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Edit(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "size"))
		{
			ShowSizeMenu(client);
		}
		else if (StrEqual(info, "origin"))
		{
			ServerCommand("sm_nav_prereq_set_origin");
			GetClientAbsOrigin(client, g_CurrentOrigin);
			SyncActiveCacheEntry();
			ReplyToCommand(client, "Moved to your position.");
			ShowEditMenu(client);
		}
		else if (StrEqual(info, "team"))
		{
			ShowTeamMenu(client);
		}
		else if (StrEqual(info, "task"))
		{
			ShowTaskMenu(client);
		}
		else if (StrEqual(info, "watchdoor"))
		{
			ShowWatchDoorMenu(client);
		}
		else if (StrEqual(info, "delete"))
		{
			ShowDeleteConfirm(client);
		}
		else if (StrEqual(info, "toggle"))
		{
			ShowToggleTypeMenu(client);
		}
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowMainMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowDeleteConfirm(int client)
{
	Menu menu = new Menu(MenuHandler_DeleteConfirm);
	menu.SetTitle("Delete this prerequisite? This cannot be undone.");
	menu.AddItem("yes", "Yes, delete it");
	menu.AddItem("no", "No, go back");
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_DeleteConfirm(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "yes"))
		{
			ServerCommand("sm_nav_prereq_delete");
			g_bMarked = false;

			if (g_ActiveCacheIndex != -1 && g_ActiveCacheIndex < g_PrereqCache.Length)
			{
				g_PrereqCache.Erase(g_ActiveCacheIndex);
			}

			g_ActiveCacheIndex = -1;
			ReplyToCommand(client, "Deleted.");
			ShowMainMenu(client);
		}
		else
		{
			ShowEditMenu(client);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowTeamMenu(int client)
{
	char folder[32];
	GetGameFolderName(folder, sizeof(folder));

	if (!StrEqual(folder, "zps", false))
	{
		ReplyToCommand(client, "Team menu not configured for game folder \"%s\" (only ZPS supported so far).", folder);
		return;
	}

	Menu menu = new Menu(MenuHandler_Team);
	menu.SetTitle("Set Team");
	menu.AddItem("2", "Survivors (#2)");
	menu.AddItem("3", "Zombies (#3)");
	menu.AddItem("-2", "Any (#-2)");
	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Team(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(position, info, sizeof(info));

		ServerCommand("sm_nav_prereq_set_team %s", info);
		g_CurrentTeam = StringToInt(info);
		SyncActiveCacheEntry();
		ReplyToCommand(client, "Team set.");
		ShowTeamMenu(client);
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowEditMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowTaskMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Task);
	menu.SetTitle("Set Task");
	menu.AddItem("0", "None");
	menu.AddItem("1", "Wait", ITEMDRAW_DISABLED);
	menu.AddItem("2", "Move To Pos", ITEMDRAW_DISABLED);
	menu.AddItem("3", "Destroy Entity");
	menu.AddItem("4", "Use Entity");
	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Task(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "3"))
		{
			ShowEntityTaskMenu(client, "3", "Destroy Entity");
			return 0;
		}

		if (StrEqual(info, "4"))
		{
			ShowEntityTaskMenu(client, "4", "Use Entity");
			return 0;
		}

		ServerCommand("sm_nav_prereq_set_task %s", info);
		strcopy(g_PendingTaskInfo, sizeof(g_PendingTaskInfo), info);
		g_CurrentGoalClassname[0] = '\0';
		SyncActiveCacheEntry();
		ReplyToCommand(client, "Task set.");
		ShowTaskMenu(client);
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowEditMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowEntityTaskMenu(int client, const char[] taskInfo, const char[] taskLabel)
{
	strcopy(g_PendingTaskInfo, sizeof(g_PendingTaskInfo), taskInfo);
	strcopy(g_PendingTaskLabel, sizeof(g_PendingTaskLabel), taskLabel);

	ServerCommand("sm_nav_prereq_set_task %s", taskInfo);

	Menu menu = new Menu(MenuHandler_EntityTask);
	menu.SetTitle("%s -- aim at entity then press Select", taskLabel);
	menu.AddItem("select", "Select");
	menu.AddItem("clear", "Clear");
	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public bool TraceFilter_EntityOnly(int entity, int contentsMask, any data)
{
	return entity != 0 && entity != data;
}

bool IsAllowedClassname(const char[] taskInfo, const char[] classname)
{
	if (StrEqual(taskInfo, "3"))
	{
		for (int i = 0; i < sizeof(g_DestroyEntityClassnames); i++)
		{
			if (StrEqual(classname, g_DestroyEntityClassnames[i], false)) { return true; }
		}
	}
	else if (StrEqual(taskInfo, "4"))
	{
		for (int i = 0; i < sizeof(g_UseEntityClassnames); i++)
		{
			if (StrEqual(classname, g_UseEntityClassnames[i], false)) { return true; }
		}
	}

	return false;
}

public int MenuHandler_EntityTask(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "clear"))
		{
			ReplyToCommand(client, "Not possible: sm_nav_prereq_set_goal_entity rejects clearing (index 0 is blocked, invalid indexes just fail). No entity-only clear exists in NavBot. Set task to None to reset fully.");
			ShowEntityTaskMenu(client, g_PendingTaskInfo, g_PendingTaskLabel);
			return 0;
		}

		// select
		float eyePos[3], eyeAng[3];
		GetClientEyePosition(client, eyePos);
		GetClientEyeAngles(client, eyeAng);

		TR_TraceRayFilter(eyePos, eyeAng, MASK_ALL, RayType_Infinite, TraceFilter_EntityOnly, client);

		int hitEntity = -1;

		if (TR_DidHit())
		{
			hitEntity = TR_GetEntityIndex();
		}

		if (hitEntity <= 0)
		{
			ReplyToCommand(client, "No entity found under your crosshair.");
			ShowEntityTaskMenu(client, g_PendingTaskInfo, g_PendingTaskLabel);
			return 0;
		}

		char classname[64];
		GetEntityClassname(hitEntity, classname, sizeof(classname));

		if (!IsAllowedClassname(g_PendingTaskInfo, classname))
		{
			ReplyToCommand(client, "\"%s\" is not a valid entity type for %s.", classname, g_PendingTaskLabel);
			ShowEntityTaskMenu(client, g_PendingTaskInfo, g_PendingTaskLabel);
			return 0;
		}

		g_PendingEntity = hitEntity;
		strcopy(g_PendingEntityClassname, sizeof(g_PendingEntityClassname), classname);
		ShowEntityConfirmMenu(client, hitEntity);
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowTaskMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowEntityConfirmMenu(int client, int entity)
{
	char classname[64];
	GetEntityClassname(entity, classname, sizeof(classname));

	char name[64];
	GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));

	if (name[0] == '\0') { strcopy(name, sizeof(name), "<no targetname>"); }

	Menu menu = new Menu(MenuHandler_EntityConfirm);
	menu.SetTitle("%s (%s) #%d -- set as goal entity?", name, classname, entity);
	menu.AddItem("yes", "Yes");
	menu.AddItem("no", "No");
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_EntityConfirm(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "yes") && g_PendingEntity > 0)
		{
			ServerCommand("sm_nav_prereq_set_goal_entity %d", g_PendingEntity);
			strcopy(g_CurrentGoalClassname, sizeof(g_CurrentGoalClassname), g_PendingEntityClassname);
			g_CurrentGoalEntity = g_PendingEntity;
			SyncActiveCacheEntry();
			ReplyToCommand(client, "Goal entity set to #%d.", g_PendingEntity);
		}
		else
		{
			ReplyToCommand(client, "Cancelled.");
		}

		g_PendingEntity = -1;
		ShowEntityTaskMenu(client, g_PendingTaskInfo, g_PendingTaskLabel);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowToggleTypeMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ToggleType);
	menu.SetTitle("Toggle Condition Type");
	menu.AddItem("1", "Entity Exists");
	menu.AddItem("2", "Entity Alive");
	menu.AddItem("3", "Entity Enabled");
	menu.AddItem("4", "Entity Locked");
	menu.AddItem("8", "Entity Visible");
	menu.AddItem("5", "Entity Team");
	menu.AddItem("6", "Entity Toggle State");
	menu.AddItem("clear", "Clear");
	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ToggleType(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		char label[32];
		menu.GetItem(position, info, sizeof(info), _, label, sizeof(label));

		if (StrEqual(info, "clear"))
		{
			ServerCommand("sm_nav_prereq_set_toggle_condition -clear");
			ReplyToCommand(client, "Toggle condition cleared.");
			ShowToggleTypeMenu(client);
			return 0;
		}

		g_PendingToggleType = StringToInt(info);
		strcopy(g_PendingToggleLabel, sizeof(g_PendingToggleLabel), label);

		if (g_CurrentGoalEntity > 0)
		{
			ShowToggleEntityChoiceMenu(client);
		}
		else
		{
			ShowToggleTraceMenu(client);
		}
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowEditMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowToggleEntityChoiceMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ToggleEntityChoice);
	menu.SetTitle("%s -- which entity?", g_PendingToggleLabel);

	char taskLabel[64];
	Format(taskLabel, sizeof(taskLabel), "Use Task Entity (#%d %s)", g_CurrentGoalEntity, g_CurrentGoalClassname);
	menu.AddItem("task", taskLabel);
	menu.AddItem("pick", "Pick Different Entity");
	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ToggleEntityChoice(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "task"))
		{
			g_PendingToggleEntity = g_CurrentGoalEntity;
			FinishToggleCondition(client);
		}
		else
		{
			ShowToggleTraceMenu(client);
		}
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowToggleTypeMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowToggleTraceMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ToggleTrace);
	menu.SetTitle("%s -- aim at entity then press Select", g_PendingToggleLabel);
	menu.AddItem("select", "Select");
	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ToggleTrace(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		float eyePos[3], eyeAng[3];
		GetClientEyePosition(client, eyePos);
		GetClientEyeAngles(client, eyeAng);

		TR_TraceRayFilter(eyePos, eyeAng, MASK_ALL, RayType_Infinite, TraceFilter_EntityOnly, client);

		int hitEntity = -1;

		if (TR_DidHit())
		{
			hitEntity = TR_GetEntityIndex();
		}

		if (hitEntity <= 0)
		{
			ReplyToCommand(client, "No entity found under your crosshair.");
			ShowToggleTraceMenu(client);
			return 0;
		}

		ShowToggleTraceConfirmMenu(client, hitEntity);
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowToggleTypeMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowToggleTraceConfirmMenu(int client, int entity)
{
	char classname[64];
	GetEntityClassname(entity, classname, sizeof(classname));

	char name[64];
	GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));

	if (name[0] == '\0') { strcopy(name, sizeof(name), "<no targetname>"); }

	g_PendingToggleEntity = entity;

	Menu menu = new Menu(MenuHandler_ToggleTraceConfirm);
	menu.SetTitle("%s (%s) #%d -- use for %s?", name, classname, entity, g_PendingToggleLabel);
	menu.AddItem("yes", "Yes");
	menu.AddItem("no", "No");
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ToggleTraceConfirm(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "yes"))
		{
			FinishToggleCondition(client);
		}
		else
		{
			g_PendingToggleEntity = -1;
			ReplyToCommand(client, "Cancelled.");
			ShowToggleTraceMenu(client);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void FinishToggleCondition(int client)
{
	if (g_PendingToggleType == TC_TEAM)
	{
		ShowToggleTeamValueMenu(client);
	}
	else if (g_PendingToggleType == TC_TOGGLE_STATE)
	{
		ShowToggleStateValueMenu(client);
	}
	else
	{
		g_PendingToggleValue[0] = '\0';
		ShowToggleInvertMenu(client);
	}
}

void ShowToggleInvertMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ToggleInvert);
	menu.SetTitle("Invert this condition? (i.e. trigger when NOT true)");
	menu.AddItem("yes", "Yes, invert");
	menu.AddItem("no", "No, normal");
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ToggleInvert(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(position, info, sizeof(info));

		bool invert = StrEqual(info, "yes");

		if (g_PendingToggleValue[0] != '\0')
		{
			ServerCommand("sm_nav_prereq_set_toggle_condition -setentity %d -settoggletypebyid %d -setintdata %s%s", g_PendingToggleEntity, g_PendingToggleType, g_PendingToggleValue, invert ? " -toggleinverted" : "");
		}
		else
		{
			ServerCommand("sm_nav_prereq_set_toggle_condition -setentity %d -settoggletypebyid %d%s", g_PendingToggleEntity, g_PendingToggleType, invert ? " -toggleinverted" : "");
		}

		ReplyToCommand(client, "%s set on entity #%d%s.", g_PendingToggleLabel, g_PendingToggleEntity, invert ? " (inverted)" : "");
		g_PendingToggleEntity = -1;
		ShowToggleTypeMenu(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowToggleTeamValueMenu(int client)
{
	char folder[32];
	GetGameFolderName(folder, sizeof(folder));

	if (!StrEqual(folder, "zps", false))
	{
		ReplyToCommand(client, "Team values not configured for game folder \"%s\" (only ZPS supported so far).", folder);
		return;
	}

	Menu menu = new Menu(MenuHandler_ToggleTeamValue);
	menu.SetTitle("Match team on entity #%d?", g_PendingToggleEntity);
	menu.AddItem("2", "Survivors (#2)");
	menu.AddItem("3", "Zombies (#3)");
	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ToggleTeamValue(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(position, info, sizeof(info));

		strcopy(g_PendingToggleValue, sizeof(g_PendingToggleValue), info);
		ShowToggleInvertMenu(client);
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowToggleTypeMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowToggleStateValueMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ToggleStateValue);
	menu.SetTitle("Match toggle state on entity #%d?", g_PendingToggleEntity);
	menu.AddItem("0", "At Top (#0)");
	menu.AddItem("1", "At Bottom (#1)");
	menu.AddItem("2", "Going Up (#2)");
	menu.AddItem("3", "Going Down (#3)");
	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ToggleStateValue(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(position, info, sizeof(info));

		strcopy(g_PendingToggleValue, sizeof(g_PendingToggleValue), info);
		ShowToggleInvertMenu(client);
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowToggleTypeMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowWatchDoorMenu(int client)
{
	char folder[32];
	GetGameFolderName(folder, sizeof(folder));

	if (!StrEqual(folder, "zps", false))
	{
		ReplyToCommand(client, "Watch Door not configured for game folder \"%s\" (only ZPS/func_door_rotating confirmed so far).", folder);
		return;
	}

	Menu menu = new Menu(MenuHandler_WatchDoor);
	menu.SetTitle("Watch Door -- aim at func_door_rotating then press Select");
	menu.AddItem("select", "Select");
	menu.AddItem("clear", "Clear");
	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_WatchDoor(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "clear"))
		{
			ServerCommand("sm_nav_prereq_set_toggle_condition -clear");
			ReplyToCommand(client, "Toggle condition cleared.");
			ShowWatchDoorMenu(client);
			return 0;
		}

		// select
		float eyePos[3], eyeAng[3];
		GetClientEyePosition(client, eyePos);
		GetClientEyeAngles(client, eyeAng);

		TR_TraceRayFilter(eyePos, eyeAng, MASK_ALL, RayType_Infinite, TraceFilter_EntityOnly, client);

		int hitEntity = -1;

		if (TR_DidHit())
		{
			hitEntity = TR_GetEntityIndex();
		}

		if (hitEntity <= 0)
		{
			ReplyToCommand(client, "No entity found under your crosshair.");
			ShowWatchDoorMenu(client);
			return 0;
		}

		char classname[64];
		GetEntityClassname(hitEntity, classname, sizeof(classname));

		if (!StrEqual(classname, "func_door_rotating", false))
		{
			ReplyToCommand(client, "\"%s\" is not func_door_rotating.", classname);
			ShowWatchDoorMenu(client);
			return 0;
		}

		g_PendingEntity = hitEntity;
		ShowWatchDoorConfirmMenu(client, hitEntity);
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowEditMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowWatchDoorConfirmMenu(int client, int entity)
{
	char name[64];
	GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));

	if (name[0] == '\0') { strcopy(name, sizeof(name), "<no targetname>"); }

	Menu menu = new Menu(MenuHandler_WatchDoorConfirm);
	menu.SetTitle("%s (func_door_rotating) #%d -- disable this prereq once closed?", name, entity);
	menu.AddItem("yes", "Yes");
	menu.AddItem("no", "No");
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_WatchDoorConfirm(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "yes") && g_PendingEntity > 0)
		{
			ServerCommand("sm_nav_prereq_set_toggle_condition -setentity %d -settoggletypebyid %d -setintdata %d", g_PendingEntity, TOGGLE_CONDITION_ENTITY_TOGGLE_STATE, TS_AT_BOTTOM);
			ReplyToCommand(client, "Watching door #%d, disables once closed.", g_PendingEntity);
		}
		else
		{
			ReplyToCommand(client, "Cancelled.");
		}

		g_PendingEntity = -1;
		ShowWatchDoorMenu(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ApplyBounds()
{
	ServerCommand("sm_nav_prereq_set_bounds %.1f %.1f 0 %.1f %.1f %.1f", -g_HalfX, -g_HalfY, g_HalfX, g_HalfY, g_HeightZ);
	SyncActiveCacheEntry();
}

void ShowSizeMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Size);
	menu.SetTitle("Change Size");

	menu.AddItem("x+", "X+");
	menu.AddItem("x-", "X-");
	menu.AddItem("y+", "Y+");
	menu.AddItem("y-", "Y-");
	menu.AddItem("z+", "Z+");
	menu.AddItem("z-", "Z-");

	menu.ExitBackButton = true;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Size(Menu menu, MenuAction action, int client, int position)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(position, info, sizeof(info));

		if (StrEqual(info, "x+")) { g_HalfX += SIZE_STEP; }
		else if (StrEqual(info, "x-")) { g_HalfX = (g_HalfX - SIZE_STEP < 0.0) ? 0.0 : g_HalfX - SIZE_STEP; }
		else if (StrEqual(info, "y+")) { g_HalfY += SIZE_STEP; }
		else if (StrEqual(info, "y-")) { g_HalfY = (g_HalfY - SIZE_STEP < 0.0) ? 0.0 : g_HalfY - SIZE_STEP; }
		else if (StrEqual(info, "z+")) { g_HeightZ += SIZE_STEP; }
		else if (StrEqual(info, "z-")) { g_HeightZ = (g_HeightZ - SIZE_STEP < 0.0) ? 0.0 : g_HeightZ - SIZE_STEP; }

		ApplyBounds();
		ShowSizeMenu(client);
	}
	else if (action == MenuAction_Cancel)
	{
		if (position == MenuCancel_ExitBack) { ShowEditMenu(client); }
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}
