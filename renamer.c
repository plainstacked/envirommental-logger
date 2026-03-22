#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdint.h>
#include <time.h>

/* ── tunables ─────────────────────────────────────────────── */
#define MAX_VARS       (1 << 16)
#define MAX_SYMS       (1 << 17)
#define MAX_HINTS      96
#define MAX_NAME       256
#define HTAB_BITS      18
#define HTAB_SIZE      (1 << HTAB_BITS)
#define HTAB_MASK      (HTAB_SIZE - 1)
#define SCOPE_DEPTH    512
#define MIN_SCORE      3
#define ALIAS_PASSES   5
#define STR_MAX        512

/* ── token types ──────────────────────────────────────────── */
typedef enum { TK_EOF=0,TK_NAME,TK_NUMBER,TK_STRING,TK_LONGSTR,TK_OP,TK_KEYWORD } TT;
typedef struct { TT type; int start,len,line; } Tok;

/* ── type universe ────────────────────────────────────────── */
typedef enum {
    TY_UNK=0,TY_NIL,TY_BOOL,TY_NUM,TY_STR,
    TY_FN,TY_TBL,TY_USERDATA,TY_THREAD,
    TY_INST,TY_SVC,TY_REMOTE,TY_REMOTEFN,TY_BINDABLE,
    TY_TWEEN,TY_ANIMTRACK,TY_CONN,
    TY_PLAYER,TY_CHAR,TY_HUMANOID,TY_PART,TY_GUI,
    TY_SOUND,TY_SCRIPT,TY_MODULE,TY_DATASTORE,
    TY_VEC3,TY_VEC2,TY_CF,TY_COLOR,TY_UDIM2,
    TY_ENUM,TY_RAY_RES,TY_PATH,TY_WAYPOINT,
    TY_CHUNK,TY_LIB,
    /* instance subtypes */
    TY_BASEPART, TY_MODEL, TY_ATTACHMENT, TY_CONSTRAINT,
    TY_LIGHT, TY_DECAL, TY_PARTICLES, TY_BILLBOARDGUI,
    TY_PROXPROMPT, TY_CLICKDET, TY_TOOL, TY_ANIM,
    TY_ANIMATOR, TY_WELD, TY_MOTOR, TY_FOLDER,
    TY_TEXTLABEL, TY_TEXTBUTTON, TY_FRAME, TY_SCREENGUI,
    TY_IMAGELABEL,TY_TEXTBOX,
    TY_INTVAL, TY_STRVAL, TY_NUMVAL, TY_BOOLVAL,
    TY_EXPLOSION, TY_BEAM, TY_TRAIL,
} Ty;

/* ── hint kinds ───────────────────────────────────────────── */
typedef enum {
    H_ALIAS=1,H_CALL,H_METHOD,H_STRARG,H_FIELD,
    H_LITSTR,H_LITNUM,H_LITBOOL,H_CTOR,
    H_PARAM,H_ITER,H_LOOPVAR,H_USEMETHOD,
    H_USEFIELD,H_NUMVAL,H_CHUNK,H_LIB,
    H_FNPURPOSE,H_ARITH,
} HK;

typedef struct { HK kind; char name[MAX_NAME]; Ty type; int score; } Hint;

/* ── variable record ──────────────────────────────────────── */
typedef struct {
    char   orig[MAX_NAME];
    char   renamed[MAX_NAME];
    Hint   hints[MAX_HINTS];
    int    nhints;
    Ty     ty;
    int    uses;
    int    isFn;
    int    isLocal;
    int    numLits;
    int    arithOps;
    int    wasParam;  /* declared as function parameter at least once */
    uint32_t hash;
} Var;

typedef struct { char name[MAX_NAME]; int vi; int scope; int decl; int isParam; int isLocal; } Sym;
typedef struct { int symBase; int isFn; int isLoop; char fn[MAX_NAME]; } ScopeFrame;

/* ── globals ──────────────────────────────────────────────── */
static char        *src;
static int          srcLen;
static Tok         *toks;
static int          ntoks;
static Var         *vars;
static int          nvars;
static Sym         *syms;
static int          nsyms;
static ScopeFrame   scopes[SCOPE_DEPTH];
static int          sdepth;
static int          ht[HTAB_SIZE];
static char       **used;
static int          nused, capused;

/* ═══════════════════════════════════════════════════════════
   KNOWLEDGE BASES
══════════════════════════════════════════════════════════════ */

typedef struct { const char *k,*n; Ty t; int s; } KV;

static const KV SVC_DB[] = {
    {"Players","Players",TY_SVC,12},{"Workspace","Workspace",TY_SVC,12},
    {"ReplicatedStorage","ReplicatedStorage",TY_SVC,12},
    {"ServerStorage","ServerStorage",TY_SVC,12},
    {"ServerScriptService","ServerScriptService",TY_SVC,12},
    {"StarterGui","StarterGui",TY_SVC,11},{"StarterPack","StarterPack",TY_SVC,11},
    {"StarterPlayer","StarterPlayer",TY_SVC,11},{"Lighting","Lighting",TY_SVC,11},
    {"SoundService","SoundService",TY_SVC,11},{"RunService","RunService",TY_SVC,12},
    {"UserInputService","UserInputService",TY_SVC,12},
    {"TweenService","TweenService",TY_SVC,11},{"HttpService","HttpService",TY_SVC,11},
    {"MarketplaceService","MarketplaceService",TY_SVC,11},
    {"TeleportService","TeleportService",TY_SVC,11},
    {"PathfindingService","PathfindingService",TY_SVC,11},
    {"CollectionService","CollectionService",TY_SVC,11},
    {"PhysicsService","PhysicsService",TY_SVC,10},
    {"DataStoreService","DataStoreService",TY_SVC,12},
    {"MessagingService","MessagingService",TY_SVC,11},
    {"TextChatService","TextChatService",TY_SVC,10},
    {"TextService","TextService",TY_SVC,9},
    {"ContentProvider","ContentProvider",TY_SVC,9},
    {"Debris","Debris",TY_SVC,9},{"GuiService","GuiService",TY_SVC,9},
    {"HapticService","HapticService",TY_SVC,8},{"VRService","VRService",TY_SVC,8},
    {"ContextActionService","ContextActionService",TY_SVC,9},
    {"ProximityPromptService","ProximityPromptService",TY_SVC,9},
    {"Teams","Teams",TY_SVC,9},{"Chat","Chat",TY_SVC,8},
    {"CoreGui","CoreGui",TY_SVC,10},{"InsertService","InsertService",TY_SVC,8},
    {"BadgeService","BadgeService",TY_SVC,9},{"GroupService","GroupService",TY_SVC,9},
    {"LocalizationService","LocalizationService",TY_SVC,8},
    {NULL,NULL,TY_UNK,0}
};

/* class name → (suggested var name, type) */
static const KV CLASS_DB[] = {
    {"Part","part",TY_BASEPART,11},{"MeshPart","meshPart",TY_BASEPART,10},
    {"UnionOperation","unionPart",TY_BASEPART,9},
    {"SpecialMesh","mesh",TY_INST,8},{"CylinderMesh","mesh",TY_INST,8},
    {"BlockMesh","mesh",TY_INST,8},
    {"Model","model",TY_MODEL,11},{"Folder","folder",TY_FOLDER,9},
    {"Script","script",TY_SCRIPT,9},{"LocalScript","localScript",TY_SCRIPT,9},
    {"ModuleScript","module",TY_MODULE,10},
    {"RemoteEvent","remoteEvent",TY_REMOTE,11},
    {"RemoteFunction","remoteFunction",TY_REMOTEFN,11},
    {"BindableEvent","bindableEvent",TY_BINDABLE,10},
    {"BindableFunction","bindableFunction",TY_BINDABLE,10},
    {"StringValue","stringValue",TY_STRVAL,9},
    {"IntValue","intValue",TY_INTVAL,9},
    {"NumberValue","numberValue",TY_NUMVAL,9},
    {"BoolValue","boolValue",TY_BOOLVAL,9},
    {"ObjectValue","objectValue",TY_INST,8},
    {"Sound","sound",TY_SOUND,10},{"SoundGroup","soundGroup",TY_INST,8},
    {"Humanoid","humanoid",TY_HUMANOID,11},
    {"HumanoidDescription","humanoidDesc",TY_INST,9},
    {"Animator","animator",TY_ANIMATOR,10},
    {"Animation","animation",TY_ANIM,9},
    {"AnimationTrack","animTrack",TY_ANIMTRACK,10},
    {"Tool","tool",TY_TOOL,10},{"Backpack","backpack",TY_INST,9},
    {"Attachment","attachment",TY_ATTACHMENT,9},
    {"Motor6D","motor",TY_MOTOR,9},{"Weld","weld",TY_WELD,9},
    {"WeldConstraint","weldConstraint",TY_WELD,9},
    {"HingeConstraint","hingeConstraint",TY_CONSTRAINT,8},
    {"RodConstraint","rodConstraint",TY_CONSTRAINT,8},
    {"BallSocketConstraint","ballSocket",TY_CONSTRAINT,8},
    {"AlignPosition","alignPosition",TY_CONSTRAINT,8},
    {"AlignOrientation","alignOrientation",TY_CONSTRAINT,8},
    {"LinearVelocity","linearVelocity",TY_CONSTRAINT,8},
    {"AngularVelocity","angularVelocity",TY_CONSTRAINT,8},
    {"BillboardGui","billboard",TY_BILLBOARDGUI,9},
    {"ScreenGui","screenGui",TY_SCREENGUI,10},
    {"SurfaceGui","surfaceGui",TY_GUI,9},
    {"Frame","frame",TY_FRAME,10},
    {"ScrollingFrame","scrollFrame",TY_FRAME,9},
    {"TextLabel","label",TY_TEXTLABEL,10},
    {"TextButton","button",TY_TEXTBUTTON,10},
    {"TextBox","textBox",TY_TEXTBOX,9},
    {"ImageLabel","imageLabel",TY_IMAGELABEL,9},
    {"ImageButton","imageBtn",TY_IMAGELABEL,9},
    {"UIListLayout","listLayout",TY_INST,8},{"UIGridLayout","gridLayout",TY_INST,8},
    {"UIPageLayout","pageLayout",TY_INST,8},
    {"UICorner","corner",TY_INST,8},{"UIStroke","stroke",TY_INST,8},
    {"UIPadding","padding",TY_INST,8},{"UIScale","scale",TY_INST,7},
    {"UIGradient","gradient",TY_INST,8},
    {"PointLight","pointLight",TY_LIGHT,9},{"SpotLight","spotLight",TY_LIGHT,9},
    {"SurfaceLight","surfaceLight",TY_LIGHT,8},
    {"Decal","decal",TY_DECAL,9},{"Texture","texture",TY_DECAL,9},
    {"Trail","trail",TY_TRAIL,8},{"Beam","beam",TY_BEAM,8},
    {"ParticleEmitter","particles",TY_PARTICLES,9},
    {"Smoke","smoke",TY_PARTICLES,8},{"Fire","fire",TY_PARTICLES,8},
    {"Sparkles","sparkles",TY_PARTICLES,8},
    {"Explosion","explosion",TY_EXPLOSION,9},
    {"SelectionBox","selectionBox",TY_INST,8},
    {"SelectionSphere","selectionSphere",TY_INST,7},
    {"BoxHandleAdornment","boxAdornment",TY_INST,7},
    {"ProximityPrompt","proxPrompt",TY_PROXPROMPT,9},
    {"ClickDetector","clickDetector",TY_CLICKDET,9},
    {"VehicleSeat","vehicleSeat",TY_BASEPART,8},
    {"Seat","seat",TY_BASEPART,8},
    {"SpawnLocation","spawnLocation",TY_BASEPART,8},
    {"TrussPart","trussPart",TY_BASEPART,8},
    {"WedgePart","wedgePart",TY_BASEPART,8},
    {"CornerWedgePart","cornerWedge",TY_BASEPART,8},
    {"Configuration","config",TY_FOLDER,7},
    {"Workspace","workspace",TY_SVC,10},
    {NULL,NULL,TY_UNK,0}
};

static const KV GLOBAL_DB[] = {
    {"game","game",TY_INST,10},{"workspace","workspace",TY_SVC,10},
    {"script","script",TY_SCRIPT,10},{"Enum","enum",TY_ENUM,10},
    {"shared","shared",TY_TBL,8},{"_G","globalEnv",TY_TBL,8},
    {"print","print",TY_FN,10},{"warn","warn",TY_FN,10},
    {"error","error",TY_FN,10},{"assert","assert",TY_FN,9},
    {"pcall","safeCall",TY_FN,10},{"xpcall","safeCallEx",TY_FN,10},
    {"pairs","pairs",TY_FN,10},{"ipairs","ipairs",TY_FN,10},
    {"next","next",TY_FN,9},{"type","typeOf",TY_FN,10},
    {"typeof","typeOf",TY_FN,10},{"tostring","toString",TY_FN,10},
    {"tonumber","toNumber",TY_FN,10},{"rawget","rawGet",TY_FN,9},
    {"rawset","rawSet",TY_FN,9},{"rawequal","rawEqual",TY_FN,8},
    {"rawlen","rawLen",TY_FN,8},{"select","select",TY_FN,8},
    {"unpack","unpack",TY_FN,9},{"setmetatable","setMeta",TY_FN,9},
    {"getmetatable","getMeta",TY_FN,9},{"loadstring","loadstringFn",TY_FN,9},
    {"load","loadChunk",TY_FN,8},{"require","require",TY_FN,9},
    {"collectgarbage","collectGc",TY_FN,7},
    {"coroutine","coroutine",TY_TBL,9},{"math","math",TY_TBL,9},
    {"table","tableLib",TY_TBL,9},{"string","stringLib",TY_TBL,9},
    {"os","osLib",TY_TBL,8},{"io","ioLib",TY_TBL,7},
    {"debug","debugLib",TY_TBL,8},{"utf8","utf8",TY_TBL,8},
    {"bit","bit",TY_TBL,8},{"bit32","bit32",TY_TBL,8},
    {"task","task",TY_TBL,9},{"wait","wait",TY_FN,8},
    {"spawn","spawn",TY_FN,8},{"delay","delay",TY_FN,8},
    {"tick","tick",TY_FN,7},{"time","timeFunc",TY_FN,7},
    {"Vector3","Vector3",TY_VEC3,9},{"Vector2","Vector2",TY_VEC2,9},
    {"CFrame","CFrame",TY_CF,9},{"Color3","Color3",TY_COLOR,9},
    {"UDim2","UDim2",TY_UDIM2,9},{"UDim","UDim",TY_UNK,8},
    {"BrickColor","brickColor",TY_UNK,8},{"TweenInfo","tweenInfo",TY_UNK,8},
    {"RaycastParams","raycastParams",TY_UNK,8},
    {"Instance","Instance",TY_INST,9},{"Random","random",TY_INST,8},
    {"Ray","ray",TY_UNK,7},{"DateTime","dateTime",TY_UNK,7},
    {NULL,NULL,TY_UNK,0}
};

static const KV EXPLOIT_DB[] = {
    {"gethui","hiddenUi",TY_INST,9},{"gethiddenui","hiddenUi",TY_INST,9},
    {"getgenv","exploitEnv",TY_TBL,8},{"getrenv","robloxEnv",TY_TBL,8},
    {"getreg","registry",TY_TBL,7},{"getgc","gcObjects",TY_TBL,7},
    {"getinstances","allInstances",TY_TBL,8},
    {"getnilinstances","nilInstances",TY_TBL,7},
    {"getscripts","allScripts",TY_TBL,7},
    {"getrunningscripts","runningScripts",TY_TBL,7},
    {"getloadedmodules","loadedModules",TY_TBL,7},
    {"getcallingscript","callerScript",TY_SCRIPT,7},
    {"getconstants","constants",TY_TBL,6},{"getupvalues","upvalues",TY_TBL,6},
    {"getprotos","protos",TY_TBL,6},
    {"decompile","decompiled",TY_STR,7},
    {"readfile","fileData",TY_STR,8},{"writefile",NULL,TY_UNK,6},
    {"listfiles","files",TY_TBL,7},
    {"identifyexecutor","executorName",TY_STR,7},
    {"getexecutorname","executorName",TY_STR,7},
    {"lz4compress","compressed",TY_STR,7},
    {"lz4decompress","decompressed",TY_STR,7},
    {"hookfunction","hookedFn",TY_FN,8},{"newcclosure","cclosure",TY_FN,7},
    {"iscclosure","isCClosure",TY_BOOL,6},{"islclosure","isLClosure",TY_BOOL,6},
    {"clonefunction","clonedFn",TY_FN,7},{"checkcaller","isExploitCaller",TY_BOOL,7},
    {"fireclickdetector","clickFired",TY_UNK,7},
    {"firetouchinterest","touchFired",TY_UNK,7},
    {"fireproximityprompt","proximityFired",TY_UNK,7},
    {"sethiddenproperty","hiddenPropSet",TY_UNK,6},
    {"gethiddenproperty","hiddenPropVal",TY_UNK,6},
    {NULL,NULL,TY_UNK,0}
};

typedef struct { const char *m,*rn; Ty rt,self; int s; } MSig;
static const MSig METHOD_DB[] = {
    {"GetService","Service",TY_SVC,TY_INST,11},
    {"WaitForChild",NULL,TY_INST,TY_INST,9},
    {"FindFirstChild",NULL,TY_INST,TY_INST,9},
    {"FindFirstChildOfClass",NULL,TY_INST,TY_INST,9},
    {"FindFirstChildWhichIsA",NULL,TY_INST,TY_INST,9},
    {"FindFirstAncestor","ancestor",TY_INST,TY_INST,8},
    {"FindFirstAncestorOfClass","ancestor",TY_INST,TY_INST,8},
    {"GetChildren","children",TY_TBL,TY_INST,8},
    {"GetDescendants","descendants",TY_TBL,TY_INST,8},
    {"Clone","clone",TY_INST,TY_INST,8},
    {"GetFullName","fullPath",TY_STR,TY_INST,7},
    {"GetDebugId","debugId",TY_STR,TY_INST,6},
    {"GetAttribute","attrValue",TY_UNK,TY_INST,7},
    {"GetAttributes","attributes",TY_TBL,TY_INST,7},
    {"IsA","isInstance",TY_BOOL,TY_INST,6},
    {"IsDescendantOf","isDescendant",TY_BOOL,TY_INST,6},
    {"IsAncestorOf","isAncestor",TY_BOOL,TY_INST,6},
    {"GetPlayers","playerList",TY_TBL,TY_SVC,9},
    {"GetPlayerFromCharacter","player",TY_PLAYER,TY_SVC,9},
    {"GetPlayerByUserId","player",TY_PLAYER,TY_SVC,9},
    {"GetCharacterAppearance","appearance",TY_TBL,TY_SVC,7},
    {"GetFriends","friends",TY_TBL,TY_PLAYER,7},
    {"GetRankInGroup","groupRank",TY_NUM,TY_PLAYER,8},
    {"GetRoleInGroup","groupRole",TY_STR,TY_PLAYER,8},
    {"IsInGroup","isInGroup",TY_BOOL,TY_PLAYER,7},
    {"IsFriendsWith","isFriend",TY_BOOL,TY_PLAYER,7},
    {"LoadCharacter","character",TY_CHAR,TY_PLAYER,8},
    {"GetNetworkPing","ping",TY_NUM,TY_PLAYER,7},
    {"MoveTo",NULL,TY_UNK,TY_HUMANOID,6},
    {"TakeDamage",NULL,TY_UNK,TY_HUMANOID,8},
    {"GetState","humanoidState",TY_ENUM,TY_HUMANOID,7},
    {"ChangeState",NULL,TY_UNK,TY_HUMANOID,7},
    {"GetAppliedDescription","humanoidDesc",TY_INST,TY_HUMANOID,7},
    {"EquipTool",NULL,TY_UNK,TY_HUMANOID,7},
    {"UnequipTools",NULL,TY_UNK,TY_HUMANOID,6},
    {"LoadAnimation","animTrack",TY_ANIMTRACK,TY_ANIMATOR,9},
    {"GetPlayingAnimationTracks","playingTracks",TY_TBL,TY_ANIMATOR,7},
    {"Play",NULL,TY_UNK,TY_ANIMTRACK,7},
    {"Stop",NULL,TY_UNK,TY_ANIMTRACK,7},
    {"AdjustSpeed",NULL,TY_UNK,TY_ANIMTRACK,6},
    {"AdjustWeight",NULL,TY_UNK,TY_ANIMTRACK,6},
    {"SetPrimaryPartCFrame",NULL,TY_UNK,TY_MODEL,7},
    {"GetPrimaryPartCFrame","rootCFrame",TY_CF,TY_MODEL,7},
    {"PivotTo",NULL,TY_UNK,TY_MODEL,7},
    {"GetPivot","pivot",TY_CF,TY_MODEL,7},
    {"GetBoundingBox","boundingBox",TY_CF,TY_MODEL,7},
    {"GetExtentsSize","extentsSize",TY_VEC3,TY_MODEL,6},
    {"ApplyImpulse",NULL,TY_UNK,TY_BASEPART,6},
    {"ApplyAngularImpulse",NULL,TY_UNK,TY_BASEPART,6},
    {"GetNetworkOwner","networkOwner",TY_PLAYER,TY_BASEPART,7},
    {"GetTouchingParts","touchingParts",TY_TBL,TY_BASEPART,7},
    {"GetConnectedParts","connectedParts",TY_TBL,TY_BASEPART,6},
    {"IntersectAsync","intersection",TY_MODEL,TY_BASEPART,7},
    {"SubtractAsync","subtracted",TY_MODEL,TY_BASEPART,7},
    {"UnionAsync","union",TY_MODEL,TY_BASEPART,7},
    {"Connect","connection",TY_CONN,TY_UNK,9},
    {"Once","connection",TY_CONN,TY_UNK,8},
    {"Wait","signalResult",TY_UNK,TY_UNK,6},
    {"Disconnect",NULL,TY_UNK,TY_CONN,7},
    {"Fire",NULL,TY_UNK,TY_UNK,6},
    {"FireServer",NULL,TY_UNK,TY_REMOTE,8},
    {"FireClient",NULL,TY_UNK,TY_REMOTE,8},
    {"FireAllClients",NULL,TY_UNK,TY_REMOTE,8},
    {"InvokeServer","remoteResult",TY_UNK,TY_REMOTEFN,9},
    {"InvokeClient","clientResult",TY_UNK,TY_REMOTEFN,8},
    {"Create","tween",TY_TWEEN,TY_SVC,9},
    {"GetDataStore","dataStore",TY_DATASTORE,TY_SVC,10},
    {"GetGlobalDataStore","globalStore",TY_DATASTORE,TY_SVC,10},
    {"GetOrderedDataStore","orderedStore",TY_DATASTORE,TY_SVC,9},
    {"GetAsync","storedData",TY_UNK,TY_DATASTORE,9},
    {"SetAsync",NULL,TY_UNK,TY_DATASTORE,8},
    {"UpdateAsync",NULL,TY_UNK,TY_DATASTORE,8},
    {"IncrementAsync","newValue",TY_NUM,TY_DATASTORE,8},
    {"RemoveAsync","oldValue",TY_UNK,TY_DATASTORE,7},
    {"HttpGet","httpResponse",TY_STR,TY_SVC,9},
    {"HttpPost","httpResponse",TY_STR,TY_SVC,9},
    {"PostAsync","httpBody",TY_STR,TY_SVC,7},
    {"RequestAsync","response",TY_TBL,TY_SVC,9},
    {"JSONEncode","jsonString",TY_STR,TY_SVC,9},
    {"JSONDecode","decodedData",TY_TBL,TY_SVC,9},
    {"GenerateGUID","guid",TY_STR,TY_SVC,8},
    {"CreatePath","path",TY_PATH,TY_SVC,10},
    {"ComputeAsync",NULL,TY_UNK,TY_PATH,8},
    {"GetWaypoints","waypoints",TY_TBL,TY_PATH,9},
    {"GetProductInfo","productInfo",TY_TBL,TY_SVC,9},
    {"UserOwnsGamePassAsync","ownsPass",TY_BOOL,TY_SVC,9},
    {"PlayerOwnsAsset","ownsAsset",TY_BOOL,TY_SVC,8},
    {"GetTagged","taggedInstances",TY_TBL,TY_SVC,9},
    {"HasTag","hasTag",TY_BOOL,TY_SVC,8},
    {"GetTags","tags",TY_TBL,TY_SVC,8},
    {"BindToRenderStep",NULL,TY_UNK,TY_SVC,8},
    {"IsServer","isServer",TY_BOOL,TY_SVC,8},
    {"IsClient","isClient",TY_BOOL,TY_SVC,8},
    {"IsStudio","isStudio",TY_BOOL,TY_SVC,8},
    {"IsRunning","isRunning",TY_BOOL,TY_SVC,7},
    {"IsPaused","isPaused",TY_BOOL,TY_SVC,7},
    {"GetPropertyChangedSignal","propChanged",TY_UNK,TY_INST,8},
    {"GetMouseLocation","mousePos",TY_VEC2,TY_SVC,9},
    {"GetMouseDelta","mouseDelta",TY_VEC2,TY_SVC,8},
    {"IsKeyDown","isKeyDown",TY_BOOL,TY_SVC,8},
    {"IsMouseButtonPressed","isMouseDown",TY_BOOL,TY_SVC,8},
    {"GetKeysPressed","pressedKeys",TY_TBL,TY_SVC,8},
    {"GetSupportedGamepadKeyCodes","gamepadKeys",TY_TBL,TY_SVC,7},
    {"WorldToScreenPoint","screenPoint",TY_VEC3,TY_INST,8},
    {"ScreenPointToRay","screenRay",TY_UNK,TY_INST,8},
    {"Raycast","rayResult",TY_RAY_RES,TY_SVC,9},
    {"FindPartOnRay","rayHit",TY_BASEPART,TY_SVC,8},
    {"FindPartOnRayWithIgnoreList","rayHit",TY_BASEPART,TY_SVC,7},
    {"SetCore",NULL,TY_UNK,TY_SVC,7},
    {"SetCoreGuiEnabled",NULL,TY_UNK,TY_SVC,7},
    {"Teleport",NULL,TY_UNK,TY_SVC,7},
    {"GetLocalPlayerTeleportData","teleportData",TY_UNK,TY_SVC,8},
    {"AddItem",NULL,TY_UNK,TY_SVC,7},
    {"GetSoundIds","soundIds",TY_TBL,TY_SOUND,7},
    {"Play",NULL,TY_UNK,TY_SOUND,8},
    {"Stop",NULL,TY_UNK,TY_SOUND,7},
    {"Pause",NULL,TY_UNK,TY_SOUND,7},
    {"Resume",NULL,TY_UNK,TY_SOUND,7},
    {"Destroy",NULL,TY_UNK,TY_INST,7},
    {"Remove",NULL,TY_UNK,TY_INST,6},
    {"ClearAllChildren",NULL,TY_UNK,TY_INST,7},
    {"GetActors","actors",TY_TBL,TY_INST,7},
    {"GetNetworkOwnershipAuto","autoOwner",TY_BOOL,TY_BASEPART,6},
    {"SetNetworkOwnershipAuto",NULL,TY_UNK,TY_BASEPART,6},
    {"SetNetworkOwner",NULL,TY_UNK,TY_BASEPART,7},
    {NULL,NULL,TY_UNK,TY_UNK,0}
};

/* instance property → (suggested name, inferred type of property value, receiver type inferred) */
typedef struct { const char *f,*n; Ty vt; Ty self; int s; } FSig;
static const FSig FIELD_DB[] = {
    /* player/character chain */
    {"LocalPlayer","localPlayer",TY_PLAYER,TY_SVC,11},
    {"Character","character",TY_CHAR,TY_PLAYER,9},
    {"Humanoid","humanoid",TY_HUMANOID,TY_CHAR,10},
    {"HumanoidRootPart","rootPart",TY_BASEPART,TY_CHAR,10},
    {"PrimaryPart","primaryPart",TY_BASEPART,TY_MODEL,9},
    {"Head","head",TY_BASEPART,TY_CHAR,9},
    {"Torso","torso",TY_BASEPART,TY_CHAR,8},
    {"UpperTorso","upperTorso",TY_BASEPART,TY_CHAR,8},
    {"LowerTorso","lowerTorso",TY_BASEPART,TY_CHAR,8},
    {"LeftArm","leftArm",TY_BASEPART,TY_CHAR,8},
    {"RightArm","rightArm",TY_BASEPART,TY_CHAR,8},
    {"LeftLeg","leftLeg",TY_BASEPART,TY_CHAR,8},
    {"RightLeg","rightLeg",TY_BASEPART,TY_CHAR,8},
    {"Animator","animator",TY_ANIMATOR,TY_HUMANOID,9},
    {"PlayerGui","playerGui",TY_GUI,TY_PLAYER,9},
    {"PlayerScripts","playerScripts",TY_FOLDER,TY_PLAYER,8},
    {"Backpack","backpack",TY_INST,TY_PLAYER,8},
    {"StarterGear","starterGear",TY_INST,TY_PLAYER,7},
    /* cameras */
    {"Camera","camera",TY_INST,TY_SVC,9},
    {"CurrentCamera","camera",TY_INST,TY_SVC,9},
    /* geometry */
    {"Parent","parent",TY_INST,TY_INST,7},
    {"CFrame","cframe",TY_CF,TY_BASEPART,9},
    {"Position","position",TY_VEC3,TY_BASEPART,9},
    {"Size","size",TY_VEC3,TY_BASEPART,8},
    {"Orientation","orientation",TY_VEC3,TY_BASEPART,8},
    {"LookVector","lookVector",TY_VEC3,TY_CF,8},
    {"RightVector","rightVector",TY_VEC3,TY_CF,7},
    {"UpVector","upVector",TY_VEC3,TY_CF,7},
    {"Velocity","velocity",TY_VEC3,TY_BASEPART,8},
    {"AssemblyLinearVelocity","linearVelocity",TY_VEC3,TY_BASEPART,8},
    {"AssemblyAngularVelocity","angularVelocity",TY_VEC3,TY_BASEPART,7},
    {"RotVelocity","rotVelocity",TY_VEC3,TY_BASEPART,7},
    {"Mass","mass",TY_NUM,TY_BASEPART,7},
    {"Density","density",TY_NUM,TY_BASEPART,7},
    {"Transparency","transparency",TY_NUM,TY_BASEPART,8},
    {"Reflectance","reflectance",TY_NUM,TY_BASEPART,7},
    {"Anchored","anchored",TY_BOOL,TY_BASEPART,8},
    {"CanCollide","canCollide",TY_BOOL,TY_BASEPART,8},
    {"CanTouch","canTouch",TY_BOOL,TY_BASEPART,7},
    {"CastShadow","castShadow",TY_BOOL,TY_BASEPART,7},
    {"Locked","locked",TY_BOOL,TY_BASEPART,6},
    {"Color","color",TY_COLOR,TY_BASEPART,8},
    {"BrickColor","brickColor",TY_UNK,TY_BASEPART,7},
    {"Material","material",TY_ENUM,TY_BASEPART,7},
    {"Shape","shape",TY_ENUM,TY_BASEPART,6},
    {"BackgroundColor3","bgColor",TY_COLOR,TY_GUI,7},
    {"TextColor3","textColor",TY_COLOR,TY_GUI,7},
    {"ImageColor3","imageColor",TY_COLOR,TY_GUI,7},
    {"BorderColor3","borderColor",TY_COLOR,TY_GUI,6},
    {"BorderSizePixel","borderSize",TY_NUM,TY_GUI,6},
    {"Text","text",TY_STR,TY_GUI,8},
    {"Font","font",TY_ENUM,TY_GUI,6},
    {"TextSize","textSize",TY_NUM,TY_GUI,7},
    {"TextScaled","textScaled",TY_BOOL,TY_GUI,6},
    {"TextWrapped","textWrapped",TY_BOOL,TY_GUI,6},
    {"Image","image",TY_STR,TY_GUI,7},
    {"Visible","visible",TY_BOOL,TY_GUI,7},
    {"Enabled","enabled",TY_BOOL,TY_INST,7},
    {"Active","active",TY_BOOL,TY_GUI,6},
    {"ZIndex","zIndex",TY_NUM,TY_GUI,6},
    {"ClipsDescendants","clipsDescendants",TY_BOOL,TY_GUI,6},
    {"Size","size",TY_UDIM2,TY_GUI,8},
    {"Position","position",TY_UDIM2,TY_GUI,8},
    {"AnchorPoint","anchorPoint",TY_VEC2,TY_GUI,7},
    {"AbsoluteSize","absoluteSize",TY_VEC2,TY_GUI,7},
    {"AbsolutePosition","absolutePos",TY_VEC2,TY_GUI,7},
    {"ViewportSize","viewportSize",TY_VEC2,TY_INST,8},
    {"TextBounds","textBounds",TY_VEC2,TY_GUI,7},
    /* humanoid */
    {"Health","health",TY_NUM,TY_HUMANOID,9},
    {"MaxHealth","maxHealth",TY_NUM,TY_HUMANOID,9},
    {"WalkSpeed","walkSpeed",TY_NUM,TY_HUMANOID,9},
    {"JumpPower","jumpPower",TY_NUM,TY_HUMANOID,9},
    {"JumpHeight","jumpHeight",TY_NUM,TY_HUMANOID,8},
    {"HipHeight","hipHeight",TY_NUM,TY_HUMANOID,8},
    {"AutoRotate","autoRotate",TY_BOOL,TY_HUMANOID,7},
    {"RootPart","rootPart",TY_BASEPART,TY_HUMANOID,8},
    {"MoveDirection","moveDirection",TY_VEC3,TY_HUMANOID,8},
    {"LookDirection","lookDirection",TY_VEC3,TY_HUMANOID,7},
    /* player info */
    {"UserId","userId",TY_NUM,TY_PLAYER,9},
    {"DisplayName","displayName",TY_STR,TY_PLAYER,8},
    {"Name","name",TY_STR,TY_INST,7},
    {"ClassName","className",TY_STR,TY_INST,8},
    {"AccountAge","accountAge",TY_NUM,TY_PLAYER,7},
    {"MembershipType","membershipType",TY_ENUM,TY_PLAYER,7},
    {"Team","team",TY_INST,TY_PLAYER,7},
    {"TeamColor","teamColor",TY_UNK,TY_PLAYER,7},
    {"RespawnLocation","respawnLocation",TY_BASEPART,TY_PLAYER,7},
    /* sound */
    {"SoundId","soundId",TY_STR,TY_SOUND,9},
    {"Volume","volume",TY_NUM,TY_SOUND,8},
    {"PlaybackSpeed","playbackSpeed",TY_NUM,TY_SOUND,7},
    {"PlaybackLoudness","loudness",TY_NUM,TY_SOUND,7},
    {"IsPlaying","isPlaying",TY_BOOL,TY_SOUND,8},
    {"IsPaused","isPaused",TY_BOOL,TY_SOUND,7},
    {"TimePosition","timePosition",TY_NUM,TY_SOUND,7},
    {"TimeLength","timeLength",TY_NUM,TY_SOUND,7},
    {"Looped","looped",TY_BOOL,TY_SOUND,7},
    {"RollOffMaxDistance","rollOffMax",TY_NUM,TY_SOUND,6},
    /* lighting */
    {"Brightness","brightness",TY_NUM,TY_LIGHT,7},
    {"Range","range",TY_NUM,TY_LIGHT,7},
    {"ShadowSoftness","shadowSoftness",TY_NUM,TY_LIGHT,6},
    /* camera */
    {"FieldOfView","fieldOfView",TY_NUM,TY_INST,7},
    {"CameraType","cameraType",TY_ENUM,TY_INST,7},
    {"CameraSubject","cameraSubject",TY_INST,TY_INST,7},
    /* data value instances */
    {"Value","value",TY_UNK,TY_INST,8},
    /* signals */
    {"OnClientEvent","onClientEvent",TY_UNK,TY_REMOTE,9},
    {"OnServerEvent","onServerEvent",TY_UNK,TY_REMOTE,9},
    {"OnClientInvoke","onClientInvoke",TY_UNK,TY_REMOTEFN,9},
    {"OnServerInvoke","onServerInvoke",TY_UNK,TY_REMOTEFN,9},
    {"Heartbeat","heartbeat",TY_UNK,TY_SVC,9},
    {"RenderStepped","renderStepped",TY_UNK,TY_SVC,9},
    {"Stepped","stepped",TY_UNK,TY_SVC,9},
    {"PostSimulation","postSimulation",TY_UNK,TY_SVC,8},
    {"PreSimulation","preSimulation",TY_UNK,TY_SVC,8},
    {"Changed","changed",TY_UNK,TY_INST,8},
    {"ChildAdded","childAdded",TY_UNK,TY_INST,8},
    {"ChildRemoved","childRemoved",TY_UNK,TY_INST,8},
    {"DescendantAdded","descendantAdded",TY_UNK,TY_INST,8},
    {"DescendantRemoving","descendantRemoving",TY_UNK,TY_INST,8},
    {"AncestryChanged","ancestryChanged",TY_UNK,TY_INST,7},
    {"PlayerAdded","playerAdded",TY_UNK,TY_SVC,9},
    {"PlayerRemoving","playerRemoving",TY_UNK,TY_SVC,9},
    {"CharacterAdded","characterAdded",TY_UNK,TY_PLAYER,9},
    {"CharacterRemoving","characterRemoving",TY_UNK,TY_PLAYER,9},
    {"Touched","touched",TY_UNK,TY_BASEPART,8},
    {"TouchEnded","touchEnded",TY_UNK,TY_BASEPART,8},
    {"InputBegan","inputBegan",TY_UNK,TY_SVC,9},
    {"InputEnded","inputEnded",TY_UNK,TY_SVC,9},
    {"InputChanged","inputChanged",TY_UNK,TY_SVC,8},
    {"MouseButton1Click","mouseClick",TY_UNK,TY_GUI,8},
    {"MouseButton1Down","mouseDown",TY_UNK,TY_GUI,8},
    {"MouseButton1Up","mouseUp",TY_UNK,TY_GUI,8},
    {"MouseButton2Click","rightClick",TY_UNK,TY_GUI,7},
    {"Activated","activated",TY_UNK,TY_GUI,8},
    {"Deactivated","deactivated",TY_UNK,TY_TOOL,7},
    {"FocusLost","focusLost",TY_UNK,TY_GUI,8},
    {"Focused","focused",TY_UNK,TY_GUI,8},
    {"Died","died",TY_UNK,TY_HUMANOID,8},
    {"StateChanged","stateChanged",TY_UNK,TY_HUMANOID,7},
    {"Seated","seated",TY_UNK,TY_HUMANOID,7},
    {"Swimming","swimming",TY_UNK,TY_HUMANOID,6},
    {"Triggered","triggered",TY_UNK,TY_PROXPROMPT,9},
    {"TriggerEnded","triggerEnded",TY_UNK,TY_PROXPROMPT,8},
    {"MouseClick","mouseClick",TY_UNK,TY_CLICKDET,9},
    /* raycast result */
    {"Instance","instance",TY_INST,TY_RAY_RES,9},
    {"Normal","normal",TY_VEC3,TY_RAY_RES,8},
    {"Distance","distance",TY_NUM,TY_RAY_RES,8},
    {"Material","material",TY_ENUM,TY_RAY_RES,7},
    {"Position","position",TY_VEC3,TY_RAY_RES,8},
    {NULL,NULL,TY_UNK,TY_UNK,0}
};

typedef struct { const char *ev; int pos; const char *param; } EPHint;
static const EPHint EVT_PARAMS[] = {
    {"Touched",0,"hitPart"},{"TouchEnded",0,"hitPart"},
    {"CharacterAdded",0,"character"},{"CharacterRemoving",0,"character"},
    {"PlayerAdded",0,"player"},{"PlayerRemoving",0,"player"},
    {"InputBegan",0,"input"},{"InputBegan",1,"gameProcessed"},
    {"InputEnded",0,"input"},{"InputEnded",1,"gameProcessed"},
    {"InputChanged",0,"input"},{"Changed",0,"newValue"},
    {"ChildAdded",0,"child"},{"ChildRemoved",0,"child"},
    {"DescendantAdded",0,"descendant"},{"DescendantRemoving",0,"descendant"},
    {"Heartbeat",0,"deltaTime"},{"RenderStepped",0,"deltaTime"},
    {"Stepped",0,"time"},{"Stepped",1,"deltaTime"},
    {"Died",0,"newState"},{"StateChanged",0,"oldState"},{"StateChanged",1,"newState"},
    {"Triggered",0,"player"},{"TriggerEnded",0,"player"},
    {"MouseClick",0,"player"},
    {"Activated",0,"inputObj"},{"Activated",1,"clickCount"},
    {"FocusLost",0,"enterPressed"},{"FocusLost",1,"inputObj"},
    {NULL,0,NULL}
};

typedef struct { const char *pat; const char *lib; } LibPat;
static const LibPat LIB_PATS[] = {
    {"Orion","Orion"},{"orion","Orion"},{"rayfield","Rayfield"},{"Rayfield","Rayfield"},
    {"Kavo","Kavo"},{"kavo","Kavo"},{"Fluent","Fluent"},{"fluent","Fluent"},
    {"SirHurt","SirHurt"},{"sirhurt","SirHurt"},
    {"Infinite%20Yield","InfiniteYield"},{"infinite_yield","InfiniteYield"},{"InfiniteYield","InfiniteYield"},
    {"DarkHub","DarkHub"},{"darkhub","DarkHub"},{"Dark%20Hub","DarkHub"},
    {"Vynx","Vynx"},{"vynx","Vynx"},{"Dex","Dex"},{"dex","Dex"},
    {"RemoteSpy","RemoteSpy"},{"remotespy","RemoteSpy"},
    {"Hydroxide","Hydroxide"},{"hydroxide","Hydroxide"},
    {"ESP","EspLib"},{"esp","EspLib"},{"aimbot","AimbotLib"},{"Aimbot","AimbotLib"},
    {"WallHack","WallHackLib"},{"wallhack","WallHackLib"},
    {"SpeedHack","SpeedHackLib"},{"speedhack","SpeedHackLib"},
    {"Admin","AdminLib"},{"admin","AdminLib"},
    {"Hub","Hub"},{"hub","Hub"},{"Menu","Menu"},{"menu","Menu"},
    {"Loader","Loader"},{"loader","Loader"},{"Panel","Panel"},
    {NULL,NULL}
};

/* ═══════════════════════════════════════════════════════════
   UTILITIES
══════════════════════════════════════════════════════════════ */
static inline uint32_t fnv(const char *s,int n){uint32_t h=2166136261u;for(int i=0;i<n;i++){h^=(uint8_t)s[i];h*=16777619u;}return h;}
static inline int teq(int i,const char *s){int l=(int)strlen(s);return toks[i].len==l&&memcmp(src+toks[i].start,s,l)==0;}
static inline int isKw(int i,const char *k){return i>=0&&i<ntoks&&toks[i].type==TK_KEYWORD&&teq(i,k);}
static inline int isOp(int i,const char *o){return i>=0&&i<ntoks&&toks[i].type==TK_OP&&teq(i,o);}
static inline int isId(int i){return i>=0&&i<ntoks&&toks[i].type==TK_NAME;}
static inline int isStr(int i){return i>=0&&i<ntoks&&(toks[i].type==TK_STRING||toks[i].type==TK_LONGSTR);}
static inline int isNum(int i){return i>=0&&i<ntoks&&toks[i].type==TK_NUMBER;}

static void ttxt(int i,char *b,int m){int l=toks[i].len<m-1?toks[i].len:m-1;memcpy(b,src+toks[i].start,l);b[l]='\0';}
static void sval(int i,char *b,int m){
    if(!isStr(i)){b[0]='\0';return;}
    const char *s=src+toks[i].start;int n=toks[i].len;
    if(toks[i].type==TK_LONGSTR){int eq=0,j=1;while(j<n&&s[j]=='='){eq++;j++;}j++;int e=n-eq-2;int cp=(e-j)<m-1?(e-j):m-1;if(cp>0)memcpy(b,s+j,cp);b[cp>0?cp:0]='\0';return;}
    char q=s[0];int j=1,o=0;
    while(j<n-1&&o<m-1){if(s[j]=='\\'){j++;if(j<n-1)switch(s[j]){case 'n':b[o++]='\n';break;case 't':b[o++]='\t';break;default:b[o++]=s[j];}}else{if(s[j]==q)break;b[o++]=s[j];}j++;}
    b[o]='\0';
}
static double parseNum(int i){char b[64];ttxt(i,b,64);return strtod(b,NULL);}

/* ═══════════════════════════════════════════════════════════
   OBFUSCATION DETECTOR  —  the single most important fn
══════════════════════════════════════════════════════════════ */
static int isBuiltin(const char *nm); /* forward decl */
static int isObfuscated(const char *nm){
    if(isBuiltin(nm))return 0;
    int n=(int)strlen(nm);
    if(n==0)return 0;

    /* single chars always rename */
    if(n==1)return 1;

    /* $, any non-ascii-ident start */
    if(!isalpha((unsigned char)nm[0])&&nm[0]!='_')return 1;

    /* hex obfuscated: _0x... or 0x... prefix vars */
    if(n>3&&nm[0]=='_'&&nm[1]=='0'&&(nm[2]=='x'||nm[2]=='X'))return 1;

    /* all underscores: _, __, ___, ... */
    {int allU=1;for(int i=0;i<n;i++)if(nm[i]!='_'){allU=0;break;}if(allU)return 1;}

    /* two or more leading underscores */
    if(n>=2&&nm[0]=='_'&&nm[1]=='_')return 1;

    /* single leading underscore + short */
    if(nm[0]=='_'&&n<=5)return 1;

    /* high O/0 confusion ratio: more than half chars are O or 0 */
    {int oz=0;for(int i=0;i<n;i++)if(nm[i]=='O'||nm[i]=='0')oz++;if(oz*2>=n&&n>=3)return 1;}

    /* alternating case entropy (lIkEtHiS or camelObf) — run of >3 alternations */
    {int alts=0,prev=-1;for(int i=0;i<n;i++){if(!isalpha((unsigned char)nm[i])){alts=0;prev=-1;continue;}int up=isupper((unsigned char)nm[i]);if(prev>=0&&up!=prev)alts++;else if(prev==up)alts=0;prev=up;if(alts>=3)return 1;}}

    /* no vowels in short names */
    if(n<=7){int v=0;for(int i=0;i<n;i++){char c=(char)tolower((unsigned char)nm[i]);if(c=='a'||c=='e'||c=='i'||c=='o'||c=='u')v++;}if(v==0)return 1;}

    /* all-lowercase + trailing digits, short */
    {int al=1,hd=0;for(int i=0;i<n;i++){if(isdigit((unsigned char)nm[i]))hd=1;else if(!islower((unsigned char)nm[i])){al=0;break;}}if(al&&hd&&n<=6)return 1;}

    /* single letter + digits: a1, b2, c3 */
    if(n>=2&&isalpha((unsigned char)nm[0])){int allD=1;for(int i=1;i<n;i++)if(!isdigit((unsigned char)nm[i])){allD=0;break;}if(allD)return 1;}

    /* keep these known-good 2-4 char words */
    if(n<=4){static const char *keep[]={"idx","len","pos","end","key","val","err","msg","ret","arg","num","buf","res","out","cur","tmp","obj","cnt","max","min","dur","str","ptr","ref","bit","mod","fmt","dt","ok","id","hp","ui","db","fn","cb",NULL};for(int k=0;keep[k];k++)if(!strcmp(nm,keep[k]))return 0;return 1;}

    return 0;
}

/* ═══════════════════════════════════════════════════════════
   VAR TABLE
══════════════════════════════════════════════════════════════ */
static int varFind(const char *nm,int l){
    uint32_t h=fnv(nm,l);int sl=(int)(h&HTAB_MASK);
    for(int k=0;k<HTAB_SIZE;k++){int idx=ht[(sl+k)&HTAB_MASK];if(idx<0)return -1;if(vars[idx].hash==h){int ol=(int)strlen(vars[idx].orig);if(ol==l&&memcmp(vars[idx].orig,nm,l)==0)return idx;}}
    return -1;
}
static int varGet(const char *nm,int l){
    int i=varFind(nm,l);if(i>=0)return i;if(nvars>=MAX_VARS)return -1;
    i=nvars++;Var *v=&vars[i];memset(v,0,sizeof(*v));
    int cp=l<MAX_NAME-1?l:MAX_NAME-1;memcpy(v->orig,nm,cp);
    v->hash=fnv(nm,l);int sl=(int)(v->hash&HTAB_MASK);
    for(int k=0;k<HTAB_SIZE;k++){int s2=(sl+k)&HTAB_MASK;if(ht[s2]<0){ht[s2]=i;break;}}
    return i;
}
static void addHint(int vi,HK k,const char *nm,Ty t,int s){
    if(vi<0||s<=0||!nm||!nm[0])return;
    Var *v=&vars[vi];
    for(int i=0;i<v->nhints;i++){if(v->hints[i].kind==k&&!strcmp(v->hints[i].name,nm)){if(s>v->hints[i].score)v->hints[i].score=s;if(t!=TY_UNK&&v->hints[i].type==TY_UNK)v->hints[i].type=t;return;}}
    if(v->nhints>=MAX_HINTS){int wi=0;for(int i=1;i<v->nhints;i++)if(v->hints[i].score<v->hints[wi].score)wi=i;if(s<=v->hints[wi].score)return;v->hints[wi]=(Hint){k,"",t,s};int cp=(int)strlen(nm);cp=cp<MAX_NAME-1?cp:MAX_NAME-1;memcpy(v->hints[wi].name,nm,cp);v->hints[wi].name[cp]='\0';return;}
    Hint *h=&v->hints[v->nhints++];h->kind=k;h->score=s;h->type=t;
    int cp=(int)strlen(nm);cp=cp<MAX_NAME-1?cp:MAX_NAME-1;memcpy(h->name,nm,cp);h->name[cp]='\0';
}

/* ═══════════════════════════════════════════════════════════
   SCOPE MANAGEMENT
══════════════════════════════════════════════════════════════ */
static void scopePush(int fn,int loop,const char *fnm){
    if(sdepth>=SCOPE_DEPTH-1)return;sdepth++;
    scopes[sdepth].symBase=nsyms;scopes[sdepth].isFn=fn;scopes[sdepth].isLoop=loop;
    if(fnm)strncpy(scopes[sdepth].fn,fnm,MAX_NAME-1);else scopes[sdepth].fn[0]='\0';
}
static void scopePop(void){if(sdepth>0)sdepth--;}
static Sym *declLocal(const char *nm,int dt,int ip){
    if(nsyms>=MAX_SYMS)return NULL;
    Sym *s=&syms[nsyms++];memset(s,0,sizeof(*s));
    strncpy(s->name,nm,MAX_NAME-1);
    s->scope=sdepth;s->decl=dt;s->isParam=ip;s->isLocal=1;
    int vi=varGet(nm,(int)strlen(nm));
    s->vi=vi;
    if(vi>=0){vars[vi].uses++;vars[vi].isLocal=1;if(ip)vars[vi].wasParam=1;}
    return s;
}

/* ═══════════════════════════════════════════════════════════
   LOOKUPS
══════════════════════════════════════════════════════════════ */
static const KV *svcF(const char *s){for(int k=0;SVC_DB[k].k;k++)if(!strcmp(SVC_DB[k].k,s))return&SVC_DB[k];return NULL;}
static const KV *clsF(const char *s){for(int k=0;CLASS_DB[k].k;k++)if(!strcmp(CLASS_DB[k].k,s))return&CLASS_DB[k];return NULL;}
static const KV *glbF(const char *s){for(int k=0;GLOBAL_DB[k].k;k++)if(!strcmp(GLOBAL_DB[k].k,s))return&GLOBAL_DB[k];return NULL;}
static const KV *expF(const char *s){for(int k=0;EXPLOIT_DB[k].k;k++)if(!strcmp(EXPLOIT_DB[k].k,s))return&EXPLOIT_DB[k];return NULL;}
static const MSig *mthF(const char *s){for(int k=0;METHOD_DB[k].m;k++)if(!strcmp(METHOD_DB[k].m,s))return&METHOD_DB[k];return NULL;}
static const FSig *fldF(const char *s){for(int k=0;FIELD_DB[k].f;k++)if(!strcmp(FIELD_DB[k].f,s))return&FIELD_DB[k];return NULL;}

/* ═══════════════════════════════════════════════════════════
   NUMBER → semantic name
══════════════════════════════════════════════════════════════ */
static void numName(double v,char *out,int m){
    long long iv=(long long)v;
    if(v==(double)iv){
        if(iv==0){strncpy(out,"zeroValue",m-1);return;}
        if(iv==1){strncpy(out,"oneValue",m-1);return;}
        if(iv==-1){strncpy(out,"negOne",m-1);return;}
        if(iv==2){strncpy(out,"twoValue",m-1);return;}
        if(iv==100){strncpy(out,"maxPercent",m-1);return;}
        if(iv==255){strncpy(out,"maxByte",m-1);return;}
        if(iv>0&&iv<=10){strncpy(out,"smallCount",m-1);return;}
        if(iv>10&&iv<=100){strncpy(out,"countValue",m-1);return;}
        if(iv>100&&iv<256){strncpy(out,"byteValue",m-1);return;}
        if(iv>=256&&iv<=1000){strncpy(out,"largeCount",m-1);return;}
        if(iv>1000){strncpy(out,"bigValue",m-1);return;}
        strncpy(out,"negValue",m-1);
    }else{
        if(v>=0&&v<=1){strncpy(out,"normalizedValue",m-1);}
        else if(v>1&&v<=100){strncpy(out,"floatValue",m-1);}
        else strncpy(out,"decimalValue",m-1);
    }
}

/* ═══════════════════════════════════════════════════════════
   STRING → semantic name
══════════════════════════════════════════════════════════════ */
static void libNameFromUrl(const char *url,char *out,int m){
    for(int k=0;LIB_PATS[k].pat;k++)if(strstr(url,LIB_PATS[k].pat)){snprintf(out,m,"%sLib",LIB_PATS[k].lib);return;}
    const char *ls=strrchr(url,'/');const char *st=ls?ls+1:url;
    int wp=0,cn=1;
    for(int i=0;st[i]&&st[i]!='?'&&st[i]!='#'&&wp<m-5;i++){char c=st[i];if(c=='.'||c=='-'||c=='_'||c=='%'){cn=1;continue;}if(!isalnum((unsigned char)c))continue;if(isdigit((unsigned char)c)&&wp==0)out[wp++]='n';if(cn&&isalpha((unsigned char)c)){out[wp++]=(char)toupper((unsigned char)c);cn=0;}else out[wp++]=c;}
    if(wp>2){memcpy(out+wp,"Lib",4);return;}
    strncpy(out,"loadedLib",m-1);
}
static void strName(const char *sv,char *out,int m){
    int l=(int)strlen(sv);if(l==0){out[0]='\0';return;}
    if(!strncmp(sv,"rbxassetid://",13)){strncpy(out,"assetId",m-1);return;}
    if(!strncmp(sv,"rbxasset://",11)){strncpy(out,"assetPath",m-1);return;}
    if(strstr(sv,"://"))  {libNameFromUrl(sv,out,m);return;}
    if(l<64){
        int wp=0,cn=1;
        for(int k=0;sv[k]&&wp<m-2;k++){char c=sv[k];if(c=='/'||c=='.'||c=='_'||c=='-'||c==' '||c=='\\'||c=='%'){cn=1;continue;}if(!isalnum((unsigned char)c))continue;if(isdigit((unsigned char)c)&&wp==0)out[wp++]='n';if(cn&&isalpha((unsigned char)c)){out[wp++]=(char)toupper((unsigned char)c);cn=0;}else out[wp++]=c;}
        out[wp]='\0';if(wp>1)return;
    }
    out[0]='\0';
}

/* ═══════════════════════════════════════════════════════════
   FUNCTION BODY ANALYSIS
══════════════════════════════════════════════════════════════ */
static void fnPurpose(int vi,int bodyStart,char *out,int m){
    int ret=0,dmg=0,fire=0,fireC=0,conn=0,save=0,load=0,
        tw=0,ray=0,math2=0,pr=0,gui=0,loop=0,cond=0,
        cat=0,http=0,ls=0,rTbl=0,rStr=0,rBool=0,spawn2=0,
        pcall2=0,wait2=0,loop2=0;
    int d=1,i=bodyStart;
    while(i<ntoks&&d>0){
        if(isKw(i,"function")||isKw(i,"do")||isKw(i,"then")||isKw(i,"repeat"))d++;
        if(isKw(i,"end")||isKw(i,"until"))d--;
        if(d<=0)break;
        if(isKw(i,"return")){ret++;if(isOp(i+1,"{"))rTbl++;if(isStr(i+1))rStr++;if(isKw(i+1,"true")||isKw(i+1,"false"))rBool++;}
        if(isKw(i,"for")||isKw(i,"while")||isKw(i,"repeat")){loop++;loop2++;}
        if(isKw(i,"if"))cond++;
        if(isKw(i,"spawn"))spawn2++;
        if(isKw(i,"pcall")||isKw(i,"xpcall"))pcall2++;
        if(isId(i)){
            char nm[MAX_NAME];ttxt(i,nm,MAX_NAME);
            if(!strcmp(nm,"TakeDamage"))dmg++;
            if(!strcmp(nm,"FireServer"))fire++;
            if(!strcmp(nm,"FireClient")||!strcmp(nm,"FireAllClients"))fireC++;
            if(!strcmp(nm,"Connect")||!strcmp(nm,"Once"))conn++;
            if(!strcmp(nm,"SetAsync"))save++;
            if(!strcmp(nm,"GetAsync"))load++;
            if(!strcmp(nm,"Create")&&isOp(i-1,"."))tw++;
            if(!strcmp(nm,"Raycast")||!strcmp(nm,"FindPartOnRay"))ray++;
            if(!strcmp(nm,"print")||!strcmp(nm,"warn"))pr++;
            if(!strcmp(nm,"TextLabel")||!strcmp(nm,"TextButton")||!strcmp(nm,"ScreenGui")||!strcmp(nm,"Frame")||!strcmp(nm,"ImageLabel"))gui++;
            if(!strcmp(nm,"HttpGet")||!strcmp(nm,"HttpGetAsync")||!strcmp(nm,"RequestAsync"))http++;
            if(!strcmp(nm,"loadstring")||!strcmp(nm,"load"))ls++;
            if(!strcmp(nm,"wait")||!strcmp(nm,"task"))wait2++;
        }
        if(isOp(i,"+")||isOp(i,"-")||isOp(i,"*")||isOp(i,"/")||isOp(i,"^")||isOp(i,"%"))math2++;
        if(isOp(i,".."))cat++;
        i++;
    }
    (void)vi;(void)loop2;(void)wait2;
    if(ls){strncpy(out,"executeScript",m-1);return;}
    if(http&&ret){strncpy(out,"fetchData",m-1);return;}
    if(dmg){strncpy(out,"dealDamage",m-1);return;}
    if(fire&&!ret){strncpy(out,"notifyServer",m-1);return;}
    if(fireC){strncpy(out,"notifyClient",m-1);return;}
    if(save&&load){strncpy(out,"syncDataStore",m-1);return;}
    if(save){strncpy(out,"saveData",m-1);return;}
    if(load){strncpy(out,"loadData",m-1);return;}
    if(ray){strncpy(out,"castRay",m-1);return;}
    if(tw){strncpy(out,"playTween",m-1);return;}
    if(conn){strncpy(out,"bindEvents",m-1);return;}
    if(gui&&!ret){strncpy(out,"buildGui",m-1);return;}
    if(gui&&ret){strncpy(out,"createGuiElement",m-1);return;}
    if(spawn2){strncpy(out,"spawnTask",m-1);return;}
    if(pcall2&&ret){strncpy(out,"tryCall",m-1);return;}
    if(rBool&&cond>2){strncpy(out,"checkCondition",m-1);return;}
    if(rBool){strncpy(out,"isValid",m-1);return;}
    if(rTbl){strncpy(out,"buildTable",m-1);return;}
    if(rStr&&cat){strncpy(out,"formatString",m-1);return;}
    if(rStr){strncpy(out,"getString",m-1);return;}
    if(math2>4&&ret){strncpy(out,"calculate",m-1);return;}
    if(math2>0&&cat&&ret){strncpy(out,"formatValue",m-1);return;}
    if(math2>0&&ret){strncpy(out,"compute",m-1);return;}
    if(pr&&!ret){strncpy(out,"logOutput",m-1);return;}
    if(loop&&ret){strncpy(out,"collectItems",m-1);return;}
    if(loop){strncpy(out,"iterateItems",m-1);return;}
    if(cond>3){strncpy(out,"processLogic",m-1);return;}
    if(ret){strncpy(out,"getValue",m-1);return;}
    out[0]='\0';
}

/* ═══════════════════════════════════════════════════════════
   RHS INFERENCE
══════════════════════════════════════════════════════════════ */
static void inferRhs(int vi,int j){
    if(vi<0||j>=ntoks)return;
    /* bare name */
    if(isId(j)||toks[j].type==TK_KEYWORD){
        char rn[MAX_NAME];ttxt(j,rn,MAX_NAME);
        const KV *g=glbF(rn);if(g)addHint(vi,H_ALIAS,g->n,g->t,g->s);
        const KV *e=expF(rn);if(e)addHint(vi,H_ALIAS,e->n,e->t,e->s);
        int ri=varFind(rn,(int)strlen(rn));if(ri>=0&&ri!=vi)addHint(vi,H_ALIAS,vars[ri].orig,TY_UNK,3);
    }
    /* string */
    if(isStr(j)){char sv[STR_MAX];sval(j,sv,STR_MAX);char hn[MAX_NAME];strName(sv,hn,MAX_NAME);if(hn[0])addHint(vi,H_LITSTR,hn,TY_STR,5);else addHint(vi,H_LITSTR,"stringValue",TY_STR,2);}
    /* number */
    if(isNum(j)){double v=parseNum(j);char nn[MAX_NAME];numName(v,nn,MAX_NAME);addHint(vi,H_NUMVAL,nn,TY_NUM,7);vars[vi].ty=TY_NUM;vars[vi].numLits++;}
    /* bool */
    if(isKw(j,"true")||isKw(j,"false")){addHint(vi,H_LITBOOL,"flag",TY_BOOL,4);vars[vi].ty=TY_BOOL;}
    /* table */
    if(isOp(j,"{")){addHint(vi,H_ALIAS,"data",TY_TBL,3);vars[vi].ty=TY_TBL;}
    /* function keyword */
    if(isKw(j,"function")){vars[vi].isFn=1;
        int bp=j+1;while(bp<ntoks&&!isOp(bp,"("))bp++;
        int be=bp;while(be<ntoks&&!isOp(be,")"))be++;
        char pur[MAX_NAME]="";fnPurpose(vi,be+1,pur,MAX_NAME);
        if(pur[0])addHint(vi,H_FNPURPOSE,pur,TY_FN,8);
        else addHint(vi,H_ALIAS,"fn",TY_FN,2);
    }
    if(!isId(j))return;
    /* call chain */
    char rcv[MAX_NAME]="",mth[MAX_NAME]="";
    int k=j;
    while(k<ntoks&&(isId(k)||isOp(k,".")||isOp(k,":"))){
        if(isId(k)){if(!mth[0])ttxt(k,rcv,MAX_NAME);ttxt(k,mth,MAX_NAME);}
        k++;
    }
    if(isOp(k,"(")){
        int a1=k+1;
        /* loadstring / load */
        if(!strcmp(mth,"loadstring")||!strcmp(mth,"load")){
            vars[vi].isFn=1;vars[vi].ty=TY_CHUNK;
            if(isStr(a1)){char sv[STR_MAX];sval(a1,sv,STR_MAX);if(strstr(sv,"://")||strstr(sv,"http")||strstr(sv,"raw.")){vars[vi].ty=TY_LIB;char ln[MAX_NAME];libNameFromUrl(sv,ln,MAX_NAME);addHint(vi,H_LIB,ln,TY_LIB,11);}else addHint(vi,H_CHUNK,"loadstringChunk",TY_CHUNK,9);}
            else addHint(vi,H_CHUNK,"loadstringFn",TY_CHUNK,8);
            return;
        }
        /* http as library loader */
        if(!strcmp(mth,"HttpGet")||!strcmp(mth,"HttpGetAsync")||!strcmp(mth,"PostAsync")||!strcmp(mth,"RequestAsync")){
            if(isStr(a1)){char sv[STR_MAX];sval(a1,sv,STR_MAX);if(strstr(sv,"://")){char ln[MAX_NAME];libNameFromUrl(sv,ln,MAX_NAME);addHint(vi,H_LIB,ln,TY_LIB,9);return;}}
            addHint(vi,H_CALL,"httpResponse",TY_STR,8);return;
        }
        /* GetService */
        if(!strcmp(mth,"GetService")&&isStr(a1)){char sv[MAX_NAME];sval(a1,sv,MAX_NAME);const KV *sc=svcF(sv);if(sc){addHint(vi,H_CALL,sc->n,sc->t,sc->s+2);return;}if(sv[0]){addHint(vi,H_STRARG,sv,TY_SVC,8);return;}}
        /* WaitForChild / FindFirstChild family */
        if(!strcmp(mth,"WaitForChild")||!strcmp(mth,"FindFirstChild")||!strcmp(mth,"FindFirstChildOfClass")||!strcmp(mth,"FindFirstChildWhichIsA")){
            if(isStr(a1)){char sv[MAX_NAME];sval(a1,sv,MAX_NAME);if(sv[0]){const KV *cl=clsF(sv);if(cl)addHint(vi,H_METHOD,cl->n,cl->t,cl->s+1);else addHint(vi,H_STRARG,sv,TY_INST,9);return;}}}
        /* Instance.new */
        if(!strcmp(mth,"new")&&!strcmp(rcv,"Instance")&&isStr(a1)){char sv[MAX_NAME];sval(a1,sv,MAX_NAME);const KV *cl=clsF(sv);if(cl){addHint(vi,H_CTOR,cl->n,cl->t,cl->s);return;}if(sv[0]){addHint(vi,H_CTOR,sv,TY_INST,8);return;}}
        /* type constructors */
        {const KV *g2=glbF(rcv);if(g2){
            if(g2->t==TY_VEC3){addHint(vi,H_CTOR,"vec3",TY_VEC3,8);return;}
            if(g2->t==TY_VEC2){addHint(vi,H_CTOR,"vec2",TY_VEC2,8);return;}
            if(g2->t==TY_CF){addHint(vi,H_CTOR,"cf",TY_CF,8);return;}
            if(g2->t==TY_COLOR){addHint(vi,H_CTOR,"color",TY_COLOR,8);return;}
            if(g2->t==TY_UDIM2){addHint(vi,H_CTOR,"udim2",TY_UDIM2,8);return;}
        }}
        /* semantic overrides before generic method lookup */
        if(!strcmp(mth,"Create")){addHint(vi,H_CALL,"tween",TY_TWEEN,15);vars[vi].ty=TY_TWEEN;return;}
        if(!strcmp(mth,"CreatePath")){addHint(vi,H_CALL,"path",TY_PATH,15);vars[vi].ty=TY_PATH;return;}
        /* signal field chained: obj.SomeSignal:Connect -> someSignalConn */
        if(!strcmp(mth,"Connect")||!strcmp(mth,"Once")){
            for(int scan=j;scan<k;scan++){
                if(isOp(scan,":")&&scan>j&&isId(scan-1)){
                    char fieldNm[MAX_NAME];ttxt(scan-1,fieldNm,MAX_NAME);
                    char connNm[MAX_NAME];
                    snprintf(connNm,sizeof(connNm),"%c%sConn",(char)tolower((unsigned char)fieldNm[0]),fieldNm+1);
                    addHint(vi,H_CALL,connNm,TY_CONN,15);vars[vi].ty=TY_CONN;return;
                }
            }
            addHint(vi,H_CALL,"connection",TY_CONN,15);vars[vi].ty=TY_CONN;return;
        }
        /* method lookup */
        const MSig *ms=mthF(mth);if(ms){if(ms->rn)addHint(vi,H_METHOD,ms->rn,ms->rt,ms->s);else addHint(vi,H_METHOD,mth,ms->rt,ms->s-2);return;}
        /* exploit */
        const KV *ex=expF(mth);if(ex){addHint(vi,H_CALL,ex->n,ex->t,ex->s);return;}
        /* generic fallback camelCase */
        if(strlen(mth)>2){char c2[MAX_NAME];snprintf(c2,sizeof(c2),"%c%s",(char)tolower((unsigned char)mth[0]),mth+1);addHint(vi,H_CALL,c2,TY_UNK,3);}
        return;
    }
    /* field read: a.B (no call) */
    if(isId(j)&&isOp(j+1,".")&&isId(j+2)&&!isOp(j+3,"(")){
        char fn[MAX_NAME];ttxt(j+2,fn,MAX_NAME);
        const FSig *fe=fldF(fn);
        if(fe)addHint(vi,H_FIELD,fe->n,fe->vt,fe->s);
        else  addHint(vi,H_FIELD,fn,TY_UNK,5);
    }
}

/* ═══════════════════════════════════════════════════════════
   MAIN ANALYSIS PASS
══════════════════════════════════════════════════════════════ */
static void analyze(void){
    scopePush(0,0,NULL);
    for(int i=0;i<ntoks;i++){

        /* function definition */
        if(isKw(i,"function")){
            char fnNm[MAX_NAME]="";int j=i+1;
            if(isId(j)){
                char dot[MAX_NAME]="";int o=0,jj=j;
                while(jj<ntoks&&(isId(jj)||isOp(jj,".")||isOp(jj,":"))){
                    if(isId(jj)){int l=toks[jj].len;if(o+l<MAX_NAME-1){memcpy(dot+o,src+toks[jj].start,l);o+=l;}ttxt(jj,fnNm,MAX_NAME);}
                    else{if(o<MAX_NAME-1)dot[o++]=isOp(jj,".")?'.':':';}
                    jj++;
                }
                dot[o]='\0';
                int vi=varGet(dot,(int)strlen(dot));
                if(vi>=0){vars[vi].isFn=1;
                    int bp=jj;while(bp<ntoks&&!isOp(bp,"("))bp++;
                    int be=bp;while(be<ntoks&&!isOp(be,")"))be++;
                    char pur[MAX_NAME]="";fnPurpose(vi,be+1,pur,MAX_NAME);
                    if(pur[0])addHint(vi,H_FNPURPOSE,pur,TY_FN,8);
                }
            }
            while(j<ntoks&&!isOp(j,"("))j++;
            scopePush(1,0,fnNm);j++;int pp=0;
            while(j<ntoks&&!isOp(j,")")){
                if(isId(j)){
                    char pn[MAX_NAME];ttxt(j,pn,MAX_NAME);
                    Sym *s=declLocal(pn,j,1);int vi=s?s->vi:varGet(pn,(int)strlen(pn));
                    if(vi>=0){
                        addHint(vi,H_PARAM,"param",TY_UNK,3);
                        for(int ep=0;EVT_PARAMS[ep].ev;ep++)
                            if(!strcmp(fnNm,EVT_PARAMS[ep].ev)&&EVT_PARAMS[ep].pos==pp)
                                addHint(vi,H_PARAM,EVT_PARAMS[ep].param,TY_UNK,9);
                    }
                    pp++;
                }
                j++;
            }
            i=j;continue;
        }

        if(isKw(i,"end")){scopePop();continue;}

        /* for loops */
        if(isKw(i,"for")){
            scopePush(0,1,NULL);int j=i+1;
            if(isId(j)&&isOp(j+1,"=")){
                char vn[MAX_NAME];ttxt(j,vn,MAX_NAME);
                Sym *s=declLocal(vn,j,0);int vi=s?s->vi:varGet(vn,(int)strlen(vn));
                addHint(vi,H_LOOPVAR,"loopIndex",TY_NUM,6);i=j+1;
            } else if(isId(j)){
                int k=j,pos=0;
                while(k<ntoks&&!isKw(k,"in")&&!isKw(k,"do")){
                    if(isId(k)){
                        char vn[MAX_NAME];ttxt(k,vn,MAX_NAME);
                        Sym *s=declLocal(vn,k,0);int vi=s?s->vi:varGet(vn,(int)strlen(vn));
                        if(pos==0)addHint(vi,H_ITER,"iterKey",TY_UNK,5);
                        else      addHint(vi,H_ITER,"iterValue",TY_UNK,6);
                        if(pos==1){
                            int ip=k;while(ip<ntoks&&!isKw(ip,"in"))ip++;
                            if(isKw(ip,"in")&&isId(ip+1)){char it[MAX_NAME];ttxt(ip+1,it,MAX_NAME);
                                if(!strcmp(it,"ipairs"))addHint(vi,H_ITER,"arrayItem",TY_UNK,7);
                                else if(!strcmp(it,"pairs"))addHint(vi,H_ITER,"tableValue",TY_UNK,6);}
                        }
                        pos++;
                    }
                    k++;
                }
                i=k;
            }
            continue;
        }

        /* local declarations */
        if(isKw(i,"local")){
            int j=i+1;
            if(isKw(j,"function")&&isId(j+1)){
                char fn[MAX_NAME];ttxt(j+1,fn,MAX_NAME);
                Sym *s=declLocal(fn,j+1,0);int vi=s?s->vi:varGet(fn,(int)strlen(fn));
                if(vi>=0){vars[vi].isFn=1;
                    int bp=j+1;while(bp<ntoks&&!isOp(bp,"("))bp++;
                    int be=bp;while(be<ntoks&&!isOp(be,")"))be++;
                    char pur[MAX_NAME]="";fnPurpose(vi,be+1,pur,MAX_NAME);
                    if(pur[0])addHint(vi,H_FNPURPOSE,pur,TY_FN,8);}
                i=j+1;continue;
            }
            int lhs[32];int nl=0;
            while(j<ntoks&&isId(j)&&nl<32){
                char vn[MAX_NAME];ttxt(j,vn,MAX_NAME);
                Sym *s=declLocal(vn,j,0);lhs[nl++]=s?s->vi:varGet(vn,(int)strlen(vn));
                j++;if(!isOp(j,","))break;j++;
            }
            if(isOp(j,"=")){j++;
                for(int li=0;li<nl;li++){
                    if(li>0){int d=0;while(j<ntoks){if(isOp(j,"(")||isOp(j,"{")||isOp(j,"["))d++;else if(isOp(j,")")||isOp(j,"}")||isOp(j,"]"))d--;else if(isOp(j,",")&&d==0){j++;break;}else if((isKw(j,"local")||isKw(j,"end")||isKw(j,"return"))&&d==0)break;j++;}}
                    if(j>=ntoks)break;inferRhs(lhs[li],j);
                }
            }
            i=j-1;continue;
        }

        /* bare assignment */
        if(isId(i)&&isOp(i+1,"=")&&!isOp(i+2,"=")){
            char vn[MAX_NAME];ttxt(i,vn,MAX_NAME);int vi=varGet(vn,(int)strlen(vn));inferRhs(vi,i+2);continue;
        }

        /* use tracking + arithmetic */
        if(isId(i)){
            char vn[MAX_NAME];ttxt(i,vn,MAX_NAME);int vi=varGet(vn,(int)strlen(vn));
            if(vi>=0){
                vars[vi].uses++;
                if(isOp(i-1,"+")||isOp(i-1,"-")||isOp(i-1,"*")||isOp(i-1,"/")||
                   isOp(i+1,"+")||isOp(i+1,"-")||isOp(i+1,"*")||isOp(i+1,"/"))
                    vars[vi].arithOps++;
            }
        }

        /* method call: obj:Method() — infer receiver type */
        if(isId(i)&&isOp(i+1,":")&&isId(i+2)){
            char rn[MAX_NAME];ttxt(i,rn,MAX_NAME);int rvi=varGet(rn,(int)strlen(rn));
            char mn[MAX_NAME];ttxt(i+2,mn,MAX_NAME);
            const MSig *ms=mthF(mn);
            if(ms){
                /* infer receiver type from self hint */
                Ty selfTy=ms->self;
                if(selfTy!=TY_UNK)addHint(rvi,H_USEMETHOD,mn,selfTy,ms->s-1);
                else               addHint(rvi,H_USEMETHOD,mn,TY_INST,ms->s-3);
            }
            /* hard-typed method signals */
            #define MHINT(M,N,T,S) if(!strcmp(mn,M))addHint(rvi,H_USEMETHOD,N,T,S)
            MHINT("TakeDamage","humanoid",TY_HUMANOID,10);
            MHINT("GetState","humanoid",TY_HUMANOID,9);
            MHINT("EquipTool","humanoid",TY_HUMANOID,9);
            MHINT("MoveTo","humanoid",TY_HUMANOID,8);
            MHINT("FireServer","remoteEvent",TY_REMOTE,10);
            MHINT("InvokeServer","remoteEvent",TY_REMOTEFN,9);
            MHINT("FireClient","remoteEvent",TY_REMOTE,10);
            MHINT("FireAllClients","remoteEvent",TY_REMOTE,9);
            MHINT("Connect","signal",TY_UNK,7);
            MHINT("Once","signal",TY_UNK,7);
            MHINT("Disconnect","connection",TY_CONN,8);
            MHINT("GetService","game",TY_INST,9);
            MHINT("GetAsync","dataStore",TY_DATASTORE,10);
            MHINT("SetAsync","dataStore",TY_DATASTORE,10);
            MHINT("UpdateAsync","dataStore",TY_DATASTORE,10);
            MHINT("IncrementAsync","dataStore",TY_DATASTORE,10);
            MHINT("HttpGet","httpService",TY_SVC,9);
            MHINT("HttpPost","httpService",TY_SVC,9);
            MHINT("JSONEncode","httpService",TY_SVC,9);
            MHINT("JSONDecode","httpService",TY_SVC,9);
            MHINT("RequestAsync","httpService",TY_SVC,9);
            MHINT("LoadAnimation","animator",TY_ANIMATOR,10);
            MHINT("GetPlayingAnimationTracks","animator",TY_ANIMATOR,9);
            MHINT("ComputeAsync","path",TY_PATH,10);
            MHINT("GetWaypoints","path",TY_PATH,10);
            MHINT("IsKeyDown","userInputService",TY_SVC,10);
            MHINT("IsMouseButtonPressed","userInputService",TY_SVC,10);
            MHINT("GetMouseLocation","userInputService",TY_SVC,10);
            MHINT("GetKeysPressed","userInputService",TY_SVC,10);
            MHINT("BindToRenderStep","runService",TY_SVC,10);
            MHINT("IsServer","runService",TY_SVC,9);
            MHINT("IsClient","runService",TY_SVC,9);
            MHINT("IsStudio","runService",TY_SVC,8);
            MHINT("Raycast","workspace",TY_SVC,9);
            MHINT("FindPartOnRay","workspace",TY_SVC,8);
            MHINT("PivotTo","model",TY_MODEL,8);
            MHINT("SetPrimaryPartCFrame","model",TY_MODEL,8);
            MHINT("GetPrimaryPartCFrame","model",TY_MODEL,8);
            MHINT("ApplyImpulse","part",TY_BASEPART,8);
            MHINT("GetTouchingParts","part",TY_BASEPART,8);
            MHINT("Play","sound",TY_SOUND,7);
            MHINT("Pause","sound",TY_SOUND,7);
            MHINT("Stop","sound",TY_SOUND,7);
            #undef MHINT
            continue;
        }

        /* field access: obj.Field — infer receiver type from field */
        if(isId(i)&&isOp(i+1,".")&&isId(i+2)){
            char rn[MAX_NAME];ttxt(i,rn,MAX_NAME);int rvi=varGet(rn,(int)strlen(rn));
            char fn[MAX_NAME];ttxt(i+2,fn,MAX_NAME);
            const FSig *fe=fldF(fn);
            if(fe){
                addHint(rvi,H_USEFIELD,fn,fe->self,fe->s-1);
            }
            /* hard typed field → receiver inference */
            #define FHINT(F,N,T,S) if(!strcmp(fn,F))addHint(rvi,H_USEFIELD,N,T,S)
            FHINT("LocalPlayer","players",TY_SVC,10);
            FHINT("Character","player",TY_PLAYER,9);
            FHINT("Humanoid","character",TY_CHAR,9);
            FHINT("HumanoidRootPart","character",TY_CHAR,9);
            FHINT("PlayerGui","player",TY_PLAYER,8);
            FHINT("Backpack","player",TY_PLAYER,8);
            FHINT("Health","humanoid",TY_HUMANOID,9);
            FHINT("MaxHealth","humanoid",TY_HUMANOID,9);
            FHINT("WalkSpeed","humanoid",TY_HUMANOID,9);
            FHINT("JumpPower","humanoid",TY_HUMANOID,9);
            FHINT("OnServerEvent","remoteEvent",TY_REMOTE,9);
            FHINT("OnClientEvent","remoteEvent",TY_REMOTE,9);
            FHINT("OnServerInvoke","remoteFunction",TY_REMOTEFN,9);
            FHINT("OnClientInvoke","remoteFunction",TY_REMOTEFN,9);
            FHINT("Heartbeat","runService",TY_SVC,9);
            FHINT("RenderStepped","runService",TY_SVC,9);
            FHINT("Stepped","runService",TY_SVC,9);
            FHINT("PlayerAdded","players",TY_SVC,9);
            FHINT("PlayerRemoving","players",TY_SVC,9);
            FHINT("CurrentCamera","workspace",TY_SVC,8);
            FHINT("Touched","part",TY_BASEPART,8);
            FHINT("TouchEnded","part",TY_BASEPART,8);
            FHINT("Anchored","part",TY_BASEPART,8);
            FHINT("CanCollide","part",TY_BASEPART,8);
            FHINT("Transparency","part",TY_BASEPART,7);
            FHINT("SoundId","sound",TY_SOUND,9);
            FHINT("Volume","sound",TY_SOUND,8);
            FHINT("IsPlaying","sound",TY_SOUND,8);
            FHINT("UserId","player",TY_PLAYER,9);
            FHINT("DisplayName","player",TY_PLAYER,8);
            #undef FHINT
        }
    }
}

/* ═══════════════════════════════════════════════════════════
   ALIAS PROPAGATION
══════════════════════════════════════════════════════════════ */
static const char *bestHint(Var *v,int *sc){
    int bs=-1;const char *bn=NULL;Ty bt=TY_UNK;
    for(int i=0;i<v->nhints;i++)if(v->hints[i].score>bs){bs=v->hints[i].score;bn=v->hints[i].name;bt=v->hints[i].type;}
    if(sc)*sc=bs;if(bt!=TY_UNK&&v->ty==TY_UNK)v->ty=bt;return bn;
}
static void propagate(void){
    for(int p=0;p<ALIAS_PASSES;p++){int ch=0;
        for(int i=0;i<nvars;i++){Var *v=&vars[i];
            for(int j=0;j<v->nhints;j++){if(v->hints[j].kind!=H_ALIAS)continue;
                int ti=varFind(v->hints[j].name,(int)strlen(v->hints[j].name));if(ti<0||ti==i)continue;
                Var *tv=&vars[ti];int ts;const char *tn=bestHint(tv,&ts);if(!tn||ts<MIN_SCORE)continue;
                int cs;bestHint(v,&cs);if(ts>cs){addHint(i,H_ALIAS,tn,tv->ty,ts-1);ch=1;}}}
        if(!ch)break;}
}

/* ═══════════════════════════════════════════════════════════
   NAME GENERATION
══════════════════════════════════════════════════════════════ */
static int nameTaken(const char *n){for(int i=0;i<nused;i++)if(!strcmp(used[i],n))return 1;return 0;}
static void reserveName(const char *n){if(nameTaken(n))return;if(nused>=capused){capused=capused?capused*2:2048;used=realloc(used,sizeof(char*)*capused);}used[nused++]=strdup(n);}
static void uniqueName(const char *base,char *out,int m){
    strncpy(out,base,m-1);out[m-1]='\0';if(!nameTaken(out)){reserveName(out);return;}
    for(int n2=2;n2<99999;n2++){snprintf(out,m,"%s%d",base,n2);if(!nameTaken(out)){reserveName(out);return;}}
    snprintf(out,m,"%s_",base);reserveName(out);
}

static const char *tyFallback(Ty t){
    switch(t){
        case TY_NUM:      return "numericValue";
        case TY_STR:      return "stringValue";
        case TY_BOOL:     return "boolValue";
        case TY_FN:       return "fn";
        case TY_TBL:      return "tableData";
        case TY_INST:     return "instance";
        case TY_SVC:      return "service";
        case TY_REMOTE:   return "remoteEvent";
        case TY_REMOTEFN: return "remoteFunction";
        case TY_BINDABLE: return "bindable";
        case TY_TWEEN:    return "tween";
        case TY_ANIMTRACK:return "animTrack";
        case TY_CONN:     return "connection";
        case TY_PLAYER:   return "player";
        case TY_CHAR:     return "character";
        case TY_MODEL:    return "model";
        case TY_GUI:      return "guiObject";
        case TY_SCREENGUI:return "screenGui";
        case TY_FRAME:    return "frame";
        case TY_TEXTLABEL:return "label";
        case TY_TEXTBUTTON:return "button";
        case TY_TEXTBOX:  return "textBox";
        case TY_IMAGELABEL:return "image";
        case TY_BILLBOARDGUI:return "billboard";
        case TY_SOUND:    return "sound";
        case TY_SCRIPT:   return "scriptRef";
        case TY_MODULE:   return "module";
        case TY_DATASTORE:return "dataStore";
        case TY_VEC3:     return "vec3";
        case TY_VEC2:     return "vec2";
        case TY_CF:       return "cframe";
        case TY_COLOR:    return "color";
        case TY_UDIM2:    return "udim2";
        case TY_ENUM:     return "enumValue";
        case TY_RAY_RES:  return "rayResult";
        case TY_PATH:     return "navPath";
        case TY_WAYPOINT: return "waypoint";
        case TY_CHUNK:    return "loadstringFn";
        case TY_LIB:      return "loadedLib";
        case TY_HUMANOID: return "humanoid";
        case TY_FOLDER:   return "folder";
        case TY_TOOL:     return "tool";
        case TY_ANIMATOR: return "animator";
        case TY_ATTACHMENT:return "attachment";
        case TY_WELD:     return "weld";
        case TY_MOTOR:    return "motor";
        case TY_CONSTRAINT:return "constraint";
        case TY_LIGHT:    return "light";
        case TY_DECAL:    return "decal";
        case TY_PARTICLES:return "particles";
        case TY_EXPLOSION:return "explosion";
        case TY_BEAM:     return "beam";
        case TY_TRAIL:    return "trail";
        case TY_PROXPROMPT:return "proxPrompt";
        case TY_CLICKDET: return "clickDetector";
        case TY_ANIM:     return "animation";
        case TY_INTVAL:   return "intValue";
        case TY_STRVAL:   return "stringValue";
        case TY_NUMVAL:   return "numberValue";
        case TY_BOOLVAL:  return "boolValue";
        default:          return "value";
    }
}

static void toCamel(const char *in,char *out,int m){
    int o=0,cn=1;
    for(int i=0;in[i]&&o<m-2;i++){char c=in[i];
        if(c=='_'||c==' '||c=='-'||c=='.'||c=='/')  {cn=1;continue;}
        if(!isalnum((unsigned char)c))continue;
        if(isdigit((unsigned char)c)&&o==0)out[o++]='n';
        if(cn&&isalpha((unsigned char)c)){out[o++]=(char)toupper((unsigned char)c);cn=0;}
        else out[o++]=c;
    }
    out[o]='\0';
}

static void buildName(Var *v,char *out,int m){
    int bs=-1;const char *bv=NULL;Ty ty=v->ty;HK bk=H_ALIAS;
    for(int i=0;i<v->nhints;i++)if(v->hints[i].score>bs){bs=v->hints[i].score;bv=v->hints[i].name;bk=v->hints[i].kind;if(v->hints[i].type!=TY_UNK)ty=v->hints[i].type;}
    if(ty!=TY_UNK)v->ty=ty;

    /* for typed result vars (tween/conn), ignore alias pollution */
    if(ty==TY_TWEEN||ty==TY_CONN){
        for(int i=0;i<v->nhints;i++){
            if(v->hints[i].kind==H_CALL||v->hints[i].kind==H_METHOD){
                char c2[MAX_NAME];toCamel(v->hints[i].name,c2,MAX_NAME);
                if(c2[0]){c2[0]=(char)tolower((unsigned char)c2[0]);uniqueName(c2,out,m);return;}
            }
        }
        uniqueName(tyFallback(ty),out,m);return;
    }

    /* if this var was declared as a parameter, pick best name from non-loop hints */
    if(v->wasParam){
        /* first: strong event-param hint (score>=9) */
        for(int i=0;i<v->nhints;i++){
            if(v->hints[i].kind==H_PARAM&&v->hints[i].score>=9){
                char c2[MAX_NAME];toCamel(v->hints[i].name,c2,MAX_NAME);
                if(c2[0]){c2[0]=(char)tolower((unsigned char)c2[0]);uniqueName(c2,out,m);return;}
            }
        }
        /* second: any strong non-loop, non-alias hint */
        int ps=-1;const char *pv=NULL;Ty pt=TY_UNK;
        for(int i=0;i<v->nhints;i++){
            HK hk=v->hints[i].kind;
            if(hk==H_LOOPVAR||hk==H_ITER||hk==H_ALIAS)continue;
            if(v->hints[i].score>ps){ps=v->hints[i].score;pv=v->hints[i].name;pt=v->hints[i].type;}
        }
        if(ps>=7&&pv){
            if(pt!=TY_UNK)v->ty=pt;
            char c2[MAX_NAME];toCamel(pv,c2,MAX_NAME);
            if(c2[0]){c2[0]=(char)tolower((unsigned char)c2[0]);uniqueName(c2,out,m);return;}
        }
        uniqueName("param",out,m);return;
    }

    /* library */
    if(ty==TY_LIB){if(bv&&bs>=MIN_SCORE){char c2[MAX_NAME];toCamel(bv,c2,MAX_NAME);if(c2[0]){uniqueName(c2,out,m);return;}}uniqueName("loadedLib",out,m);return;}
    /* loadstring chunk */
    if(ty==TY_CHUNK||bk==H_CHUNK){if(bv&&bs>=MIN_SCORE){char c2[MAX_NAME];toCamel(bv,c2,MAX_NAME);if(c2[0]){uniqueName(c2,out,m);return;}}uniqueName("loadstringFn",out,m);return;}
    /* function */
    if(v->isFn){if(bv&&bs>=MIN_SCORE){char c2[MAX_NAME];toCamel(bv,c2,MAX_NAME);if(c2[0]){c2[0]=(char)tolower((unsigned char)c2[0]);uniqueName(c2,out,m);return;}}uniqueName("fn",out,m);return;}

    /* good semantic hint available */
    if(bv&&bs>=MIN_SCORE){
        /* numeric value hints */
        if(ty==TY_NUM||bk==H_NUMVAL||bk==H_LOOPVAR||bk==H_ITER){
            char c2[MAX_NAME];toCamel(bv,c2,MAX_NAME);
            if(c2[0]){c2[0]=(char)tolower((unsigned char)c2[0]);uniqueName(c2,out,m);return;}
            uniqueName("numericValue",out,m);return;
        }
        char base[MAX_NAME];toCamel(bv,base,MAX_NAME);
        if(!base[0]){uniqueName(tyFallback(ty),out,m);return;}
        if(ty!=TY_SVC&&ty!=TY_REMOTE&&ty!=TY_REMOTEFN&&ty!=TY_DATASTORE)
            base[0]=(char)tolower((unsigned char)base[0]);
        uniqueName(base,out,m);return;
    }

    /* no good hint — use type or arithmetic fallback */
    if(ty==TY_NUM||v->numLits>0){uniqueName("numericValue",out,m);return;}
    if(v->arithOps>=2&&!v->isFn){uniqueName("computedValue",out,m);return;}
    uniqueName(tyFallback(ty),out,m);
}

static const char *BUILTINS[]={"print","warn","error","assert","pcall","xpcall","pairs","ipairs","next","type","typeof","tostring","tonumber","rawget","rawset","rawequal","rawlen","select","unpack","setmetatable","getmetatable","require","load","loadstring","dofile","loadfile","collectgarbage","coroutine","math","table","string","io","os","debug","utf8","bit","bit32","game","workspace","script","Enum","shared","_G","_VERSION","task","wait","spawn","delay","tick","time","elapsedTime","Vector3","Vector2","CFrame","Color3","UDim","UDim2","BrickColor","TweenInfo","Instance","Random","Ray","Rect","Region3","NumberRange","NumberSequence","ColorSequence","Font","RaycastParams","OverlapParams","PathWaypoint","DateTime","SharedTable","i","j","k","n","v","_","x","y","z","w","r","g","b","idx","len","pos","end","key","val","err","msg","ret","arg","num","buf","res","out","cur","tmp","obj","cnt","max","min","dur","str","ptr","ref","bit","mod","fmt","dt","ok","id","hp","ui","db","fn","cb",NULL};
static const char *LUA_KW[]={"and","break","do","else","elseif","end","false","for","function","goto","if","in","local","nil","not","or","repeat","return","then","true","until","while",NULL};

static int isBuiltin(const char *nm){
    /* single-char names are always obfuscated, never protect them */
    if((int)strlen(nm)<=1)return 0;
    for(int i=0;BUILTINS[i];i++)if(!strcmp(BUILTINS[i],nm))return 1;
    for(int i=0;LUA_KW[i];i++)if(!strcmp(LUA_KW[i],nm))return 1;
    static const char *safe[]={"math","self","name","type","size","data","node","list","path","file","text","time","func","call","init","base","root","step","next","prev","last","head","tail","left","right","open","read","line","page","mode","role","rule","user","team","item","find","sort","copy","join","wrap","pair","link","lock","mark","pass","skip","test","null","void","none","new","true","false","nil","game","wait","task","print","warn","error","pcall","pairs","ipairs","tostring","tonumber","typeof","table","string","math","setmetatable","getmetatable","rawget","rawset","select","unpack","require","spawn","delay","tick","time","workspace","script","Enum","shared","Vector2","Vector3","CFrame","Color3","UDim2","UDim","BrickColor","TweenInfo","Instance","Random","Ray","DateTime","RaycastParams","OverlapParams",NULL};
    for(int i=0;safe[i];i++)if(!strcmp(safe[i],nm))return 1;
    return 0;
}
static void assignNames(void){
    for(int i=0;BUILTINS[i];i++)reserveName(BUILTINS[i]);
    for(int i=0;LUA_KW[i];i++)reserveName(LUA_KW[i]);
    for(int i=0;i<nvars;i++)if(!isObfuscated(vars[i].orig)&&vars[i].uses>0)reserveName(vars[i].orig);
    for(int i=0;i<nvars;i++){Var *v=&vars[i];
        if(!isObfuscated(v->orig)){strncpy(v->renamed,v->orig,MAX_NAME-1);v->renamed[MAX_NAME-1]='\0';}
        else buildName(v,v->renamed,MAX_NAME);}
}

/* ═══════════════════════════════════════════════════════════
   LEXER — handles $, obfuscated identifiers
══════════════════════════════════════════════════════════════ */
static int luaKw(const char *s,int l){for(int k=0;LUA_KW[k];k++){int kl=(int)strlen(LUA_KW[k]);if(kl==l&&memcmp(s,LUA_KW[k],l)==0)return 1;}return 0;}

/* check if a char can start or continue an identifier in obfuscated lua */
static inline int identStart(char c){return isalpha((unsigned char)c)||c=='_'||c=='$';}
static inline int identCont(char c){return isalnum((unsigned char)c)||c=='_'||c=='$';}

static void tokenize(void){
    int cap=65536;toks=malloc(sizeof(Tok)*cap);ntoks=0;int i=0,line=1;
#define EMIT(T,S,L) do{if(ntoks>=cap){cap*=2;toks=realloc(toks,sizeof(Tok)*cap);}toks[ntoks]=(Tok){(T),(S),(L),line};ntoks++;}while(0)
    while(i<srcLen){
        char c=src[i];
        if(c=='\n'){line++;i++;continue;}if(c=='\r'||c==' '||c=='\t'){i++;continue;}
        /* comments */
        if(c=='-'&&i+1<srcLen&&src[i+1]=='-'){int j=i+2;if(j<srcLen&&src[j]=='['){int eq=0,k2=j+1;while(k2<srcLen&&src[k2]=='='){eq++;k2++;}if(k2<srcLen&&src[k2]=='['){k2++;while(k2+eq+1<srcLen){if(src[k2]=='\n')line++;if(src[k2]==']'){int m2=1;while(m2<=eq&&src[k2+m2]=='=')m2++;if(m2==eq+1&&src[k2+eq+1]==']'){k2+=eq+2;break;}}k2++;}i=k2;continue;}}while(i<srcLen&&src[i]!='\n')i++;continue;}
        /* long strings */
        if(c=='['){int eq=0,j=i+1;while(j<srcLen&&src[j]=='='){eq++;j++;}if(j<srcLen&&src[j]=='['){j++;int s2=i;while(j+eq+1<srcLen){if(src[j]=='\n')line++;if(src[j]==']'){int m2=1;while(m2<=eq&&src[j+m2]=='=')m2++;if(m2==eq+1&&src[j+eq+1]==']'){j+=eq+2;break;}}j++;}EMIT(TK_LONGSTR,s2,j-s2);i=j;continue;}}
        /* strings */
        if(c=='"'||c=='\''||c=='`'){int s2=i;i++;while(i<srcLen&&src[i]!=c){if(src[i]=='\\')i++;if(i<srcLen&&src[i]=='\n')line++;i++;}i++;EMIT(TK_STRING,s2,i-s2);continue;}
        /* numbers */
        if(isdigit((unsigned char)c)||(c=='.'&&i+1<srcLen&&isdigit((unsigned char)src[i+1]))){int s2=i;if(c=='0'&&i+1<srcLen&&(src[i+1]=='x'||src[i+1]=='X')){i+=2;while(i<srcLen&&isxdigit((unsigned char)src[i]))i++;}else{while(i<srcLen&&(isdigit((unsigned char)src[i])||src[i]=='.'||src[i]=='e'||src[i]=='E'))i++;}EMIT(TK_NUMBER,s2,i-s2);continue;}
        /* identifiers — including $ */
        if(identStart(c)){int s2=i;while(i<srcLen&&identCont(src[i]))i++;int l=i-s2;EMIT(luaKw(src+s2,l)?TK_KEYWORD:TK_NAME,s2,l);continue;}
        /* operators */
        {int s2=i;i++;char c2=i<srcLen?src[i]:0;if((c=='='&&c2=='=')||(c=='~'&&c2=='=')||(c=='<'&&c2=='=')||(c=='>'&&c2=='=')||(c=='.'&&c2=='.'&&i+1<srcLen&&src[i+1]=='.')||(c=='.'&&c2=='.')||(c==':'&&c2==':')||(c=='-'&&c2=='-'))i++;EMIT(TK_OP,s2,i-s2);}
    }
    EMIT(TK_EOF,srcLen,0);
}

/* ═══════════════════════════════════════════════════════════
   OUTPUT
══════════════════════════════════════════════════════════════ */
/* write the credit comment then the renamed source */
static void emitWithHeader(FILE *f){
    fputs("-- this renamer is made by @aerexis on discord please do not remove this comment even if youre forking this repo! or atleast dont take away credits for renamer. Enjoy the renamer!\n", f);
}
static void emit(FILE *f){
    int last=0;
    for(int i=0;i<ntoks;i++){
        if(toks[i].type!=TK_NAME)continue;
        /* skip field/method names: identifiers immediately after . or : */
        if(i>0&&(isOp(i-1,".")||isOp(i-1,":")))continue;
        char nm[MAX_NAME];ttxt(i,nm,MAX_NAME);
        int vi=varFind(nm,toks[i].len);if(vi<0)continue;
        Var *v=&vars[vi];
        if(!isObfuscated(v->orig))continue;
        if(!strcmp(v->orig,v->renamed))continue;
        fwrite(src+last,1,toks[i].start-last,f);fputs(v->renamed,f);
        last=toks[i].start+toks[i].len;
    }
    fwrite(src+last,1,srcLen-last,f);
}

/* ═══════════════════════════════════════════════════════════
   MAIN
══════════════════════════════════════════════════════════════ */
int main(int argc,char **argv){
    if(argc<2){fprintf(stderr,"Usage: %s input.lua [output.lua]\n",argv[0]);return 1;}
    FILE *f=fopen(argv[1],"rb");if(!f){perror(argv[1]);return 1;}
    fseek(f,0,SEEK_END);srcLen=(int)ftell(f);rewind(f);
    src=malloc(srcLen+4);
    if((int)fread(src,1,srcLen,f)!=srcLen){perror("read");return 1;}
    src[srcLen]='\0';fclose(f);
    vars=calloc(MAX_VARS,sizeof(Var));syms=calloc(MAX_SYMS,sizeof(Sym));
    memset(ht,-1,sizeof(ht));
    tokenize();analyze();propagate();assignNames();
    FILE *out;const char *op=argc>=3?argv[2]:NULL;
    if(op){out=fopen(op,"wb");if(!out){perror(op);return 1;}}else out=stdout;
    /* count renames for stats */
    int totalVarsRenamed=0, totalFnsRenamed=0;
    for(int i=0;i<nvars;i++){
        Var *v=&vars[i];
        if(!isObfuscated(v->orig))continue;
        if(strcmp(v->orig,v->renamed)==0)continue;
        if(v->uses==0)continue;
        totalVarsRenamed++;
        if(v->isFn)totalFnsRenamed++;
    }

    struct timespec t0,t1;
    clock_gettime(CLOCK_MONOTONIC,&t0);
    if(op){emitWithHeader(out);}
    emit(out);
    clock_gettime(CLOCK_MONOTONIC,&t1);

    long long nsElapsed=(long long)(t1.tv_sec-t0.tv_sec)*1000000000LL+(t1.tv_nsec-t0.tv_nsec);
    double msElapsed=nsElapsed/1e6;
    double secElapsed=nsElapsed/1e9;

    if(op){
        fclose(out);
        printf("output written: %s\n",op);
        printf("variables renamed : %d\n",totalVarsRenamed);
        printf("functions renamed : %d\n",totalFnsRenamed);
        printf("time              : %.9f s  /  %.4f ms  /  %lld ns\n",secElapsed,msElapsed,nsElapsed);
    }
    free(src);free(toks);free(vars);free(syms);
    for(int i=0;i<nused;i++)free(used[i]);free(used);
    return 0;
}

