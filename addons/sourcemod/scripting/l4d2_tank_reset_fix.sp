/*
 * [L4D2] Tank Reset Fix
 *
 * The director counts a bot Tank as "in play" (Director.IsTankInPlay) only while his
 * body's arousal is not neutral. Resetting a bot (CommandABot with BOT_CMD_RESET, or
 * anything else that calls INextBot::Reset) sets the arousal back to neutral at once,
 * and the Tank's attack behaviour only raises it again on his next AI update, which
 * comes after the director has already checked him at least once. For those ticks the
 * director sees no Tank: a finale's Tank stage ends early and the Tank music restarts.
 *
 * This plugin keeps the arousal a Tank had before the reset, so the director keeps
 * counting him until his AI sets it again on its own.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define PLUGIN_VERSION	"1.0"
#define GAMEDATA		"l4d2_tank_reset_fix"

#define TEAM_INFECTED	3
#define ZC_TANK			8

#define AROUSAL_NEUTRAL	0
#define AROUSAL_INTENSE	2

public Plugin myinfo =
{
	name = "[L4D2] Tank Reset Fix",
	author = "Thumos",
	description = "Keeps a bot Tank counted as in play when his AI is reset, so finales do not skip the Tank stage or restart the Tank music.",
	version = PLUGIN_VERSION,
	url = ""
};

Handle g_hMyNextBotPointer;
Handle g_hGetEntity;
Handle g_hGetBodyInterface;
Handle g_hGetArousal;
Handle g_hSetArousal;

ConVar g_cvEnable;
ConVar g_cvDebug;

bool g_bDisabled;

// The reset in progress whose arousal is restored afterwards (INextBot::Reset is not
// called recursively, so one slot is enough).
Address g_aPendingBot = Address_Null;
int g_iPendingArousal;
int g_iPendingClient;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "This plugin only supports Left 4 Dead 2.");

		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	GameData gamedata = new GameData(GAMEDATA);

	if (gamedata == null)
	{
		SetFailState("Missing gamedata/%s.txt.", GAMEDATA);
	}

	StartPrepSDKCall(SDKCall_Entity);
	PrepVirtual(gamedata, "CBaseEntity::MyNextBotPointer");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hMyNextBotPointer = EndPrep("CBaseEntity::MyNextBotPointer");

	StartPrepSDKCall(SDKCall_Raw);
	PrepVirtual(gamedata, "INextBot::GetEntity");
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
	g_hGetEntity = EndPrep("INextBot::GetEntity");

	StartPrepSDKCall(SDKCall_Raw);
	PrepVirtual(gamedata, "INextBot::GetBodyInterface");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hGetBodyInterface = EndPrep("INextBot::GetBodyInterface");

	StartPrepSDKCall(SDKCall_Raw);
	PrepSymbolOrVirtual(gamedata, "PlayerBody::GetArousal", "IBody::GetArousal");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hGetArousal = EndPrep("GetArousal");

	StartPrepSDKCall(SDKCall_Raw);
	PrepSymbolOrVirtual(gamedata, "PlayerBody::SetArousal", "IBody::SetArousal");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	g_hSetArousal = EndPrep("SetArousal");

	DynamicDetour detour = new DynamicDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Address);

	if (!detour.SetFromConf(gamedata, SDKConf_Signature, "INextBot::Reset"))
	{
		SetFailState("Could not find INextBot::Reset in gamedata/%s.txt.", GAMEDATA);
	}

	if (!detour.Enable(Hook_Pre, Detour_ResetPre) || !detour.Enable(Hook_Post, Detour_ResetPost))
	{
		SetFailState("Could not detour INextBot::Reset.");
	}

	delete gamedata;

	CreateConVar("l4d2_tank_reset_fix_version", PLUGIN_VERSION, "Tank Reset Fix version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnable = CreateConVar("l4d2_tank_reset_fix_enable", "1", "1: keep a bot Tank counted as in play through an AI reset. 0: off.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("l4d2_tank_reset_fix_debug", "0", "1: print to the server console each time a Tank's arousal is kept.", FCVAR_NONE, true, 0.0, true, 1.0);

	AutoExecConfig(true, "l4d2_tank_reset_fix");

	RegAdminCmd("sm_tank_arousal", Command_TankArousal, ADMFLAG_GENERIC, "Prints the arousal of every bot Tank (0 neutral, 1 alert, 2 intense).");
}

//=========================================================
// SDKCall setup
//=========================================================
void PrepVirtual(GameData gamedata, const char[] name)
{
	if (!PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, name))
	{
		SetFailState("Could not find the offset of %s in gamedata/%s.txt.", name, GAMEDATA);
	}
}

// Calls the function directly when its symbol is in the gamedata (Linux), otherwise
// through its virtual offset (Windows, or Linux if the symbol is not found).
void PrepSymbolOrVirtual(GameData gamedata, const char[] symbol, const char[] offset)
{
	if (gamedata.GetMemSig(symbol) != Address_Null && PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, symbol))
	{
		return;
	}

	PrepVirtual(gamedata, offset);
}

Handle EndPrep(const char[] name)
{
	Handle call = EndPrepSDKCall();

	if (call == null)
	{
		SetFailState("Could not prepare the call to %s.", name);
	}

	return call;
}

//=========================================================
// The reset
//=========================================================
public MRESReturn Detour_ResetPre(Address bot)
{
	g_aPendingBot = Address_Null;

	if (g_bDisabled || !g_cvEnable.BoolValue || bot == Address_Null)
	{
		return MRES_Ignored;
	}

	// Every NextBot (common infected, witches, bots) resets through here. Only living bot
	// Tanks go further: the arousal calls are made for the body bot players use. A bot
	// still being built has no entity index yet, so it is skipped here too.
	int client = SDKCall(g_hGetEntity, bot);

	if (!IsAliveBotTank(client))
	{
		return MRES_Ignored;
	}

	Address body = GetBody(bot);

	if (body == Address_Null)
	{
		return MRES_Ignored;
	}

	int arousal = SDKCall(g_hGetArousal, body);

	if (arousal < AROUSAL_NEUTRAL || arousal > AROUSAL_INTENSE)
	{
		// Not a valid arousal, so the gamedata does not match this build of the game.
		g_bDisabled = true;

		LogError("Read an arousal of %d, which is not valid. The gamedata does not match this version of the game, so the plugin has stopped.", arousal);

		return MRES_Ignored;
	}

	if (arousal == AROUSAL_NEUTRAL)
	{
		return MRES_Ignored;
	}

	g_aPendingBot = bot;
	g_iPendingArousal = arousal;
	g_iPendingClient = client;

	return MRES_Ignored;
}

public MRESReturn Detour_ResetPost(Address bot)
{
	if (bot == Address_Null || bot != g_aPendingBot)
	{
		return MRES_Ignored;
	}

	g_aPendingBot = Address_Null;

	Address body = GetBody(bot);

	if (body == Address_Null)
	{
		return MRES_Ignored;
	}

	SDKCall(g_hSetArousal, body, g_iPendingArousal);

	if (g_cvDebug.BoolValue && IsClientInGame(g_iPendingClient))
	{
		PrintToServer("[Tank Reset Fix] %N was reset. Kept his arousal at %d so the director still counts him as in play.", g_iPendingClient, g_iPendingArousal);
	}

	return MRES_Ignored;
}

//=========================================================
// Helpers
//=========================================================
Address GetBody(Address bot)
{
	return view_as<Address>(SDKCall(g_hGetBodyInterface, bot));
}

bool IsAliveBotTank(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && IsFakeClient(client) && GetClientTeam(client) == TEAM_INFECTED && IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_TANK;
}

public Action Command_TankArousal(int client, int args)
{
	int found = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsAliveBotTank(i))
		{
			continue;
		}

		Address bot = view_as<Address>(SDKCall(g_hMyNextBotPointer, i));
		Address body = (bot != Address_Null ? GetBody(bot) : Address_Null);

		if (body == Address_Null)
		{
			continue;
		}

		ReplyToCommand(client, "[Tank Reset Fix] %N: arousal %d (0 neutral, 1 alert, 2 intense).", i, SDKCall(g_hGetArousal, body));

		found++;
	}

	if (found == 0)
	{
		ReplyToCommand(client, "[Tank Reset Fix] No bot Tank is alive.");
	}

	return Plugin_Handled;
}
