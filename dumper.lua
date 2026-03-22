local _debug      = debug
local _sethook    = debug.sethook
local _getinfo    = debug.getinfo
local _load       = loadstring or load
local _pcall      = pcall
local _xpcall     = xpcall
local _error      = error
local _type       = type
local _getmeta    = getmetatable
local _rawequal   = rawequal
local _tostring   = tostring
local _tonumber   = tonumber
local _io         = io
local _os         = os
local _pairs      = pairs
local _ipairs     = ipairs
local _print      = print
local _warn       = (type(warn) == "function") and warn or function() end
local _select     = select
local _unpack     = table.unpack or unpack
local str_format  = string.format
local str_rep     = string.rep
local str_find    = string.find
local str_match   = string.match
local str_gsub    = string.gsub
local str_sub     = string.sub
local tbl_concat  = table.concat
local tbl_insert  = table.insert
local tbl_remove  = table.remove
local math_floor  = math.floor
local math_huge   = math.huge

local CLI = {}
do
    local raw = arg or {}

    local positional = {}
    local flags = {}
    for i = 1, #raw do
        local a = raw[i]
        if a:sub(1,2) == "--" then
            local k, v = a:match("^%-%-([%w_%-]+)=(.+)$")
            if k then
                flags[k] = v
            else
                flags[a:sub(3)] = true
            end
        else
            positional[#positional + 1] = a
        end
    end

    CLI.input       = positional[1]
    CLI.output      = positional[2]
    CLI.key         = flags["key"]         or positional[3] or "NoKey"
    CLI.game_id     = _tonumber(flags["gameid"]) or _tonumber(positional[4]) or 123456789
    CLI.timeout     = _tonumber(flags["timeout"]) or 20
    CLI.verbose     = flags["verbose"]     == true
    CLI.no_sanitize = flags["no-sanitize"] == true
    CLI.hook_op     = flags["enablehookOp"] == true

    function CLI.usage()
        _print("Usage: lua5.3 dumper.lua <input.lua> [output.lua] [flags]")
        _print("Flags:")
        _print("  --enablehookOp     Instrument source with built-in hookOp engine (Lua 5.3)")
        _print("  --verbose          Print emitted lines to stdout")
        _print("  --no-sanitize      Skip Luau->Lua syntax conversion")
        _print("  --timeout=N        Execution timeout in seconds (default: 20)")
        _print("  --key=VALUE        Script key / password hint")
        _print("  --gameid=VALUE     Fake game PlaceId")
    end
end

local CFG = {
    MAX_DEPTH          = 20,
    MAX_TABLE_ITEMS    = 500,
    OUTPUT_FILE        = CLI.output or "dumped_output.lua",
    VERBOSE            = CLI.verbose,
    TIMEOUT_SECONDS    = CLI.timeout,
    MAX_REPEATED_LINES = 6,
    MAX_OUTPUT_SIZE    = 12 * 1024 * 1024,
    HOOK_CALL_ID       = "__DUMPERHOOK_",
    TRACE_CALLBACKS    = true,
    CONSTANT_COLLECTION = true,
    INSTRUMENT_LOGIC   = true,
}
local INPUT_KEY = CLI.key
local GAME_ID   = CLI.game_id

if CLI.hook_op then
    _print("[Dumper] hookOp mode enabled — built-in instrumenter active")
end

local STATE = {}

local function reset_state()
    STATE = {
        output           = {},
        indent           = 0,
        registry         = {},
        reverse_registry = {},
        names_used       = {},
        parent_map       = {},
        property_store   = {},
        call_graph       = {},
        variable_types   = {},
        string_refs      = {},
        proxy_id         = 0,
        pending_iterator = false,
        last_http_url    = nil,
        last_line        = nil,
        rep_count        = 0,
        current_size     = 0,
        limit_reached    = false,
        lar_counter      = 0,
        var_counter      = 0,
        func_counter     = 0,
        captured_strings = {},
    }
end
reset_state()

local PROXY_SEN   = {}
local NUMPROX_SEN = {}
setmetatable(PROXY_SEN, {__mode = "k"})

local function is_num_proxy(x)
    if _type(x) ~= "table" then return false end
    local ok, r = _pcall(rawget, x, NUMPROX_SEN)
    return ok and r == true
end
local function is_proxy(x) return PROXY_SEN[x] == true end

local INDENT_CACHE = setmetatable({}, {__index = function(t, n)
    local s = str_rep("    ", n); t[n] = s; return s
end})

local function emit(line, no_indent)
    if STATE.limit_reached then return end
    if line == nil then return end
    local ind = no_indent and "" or INDENT_CACHE[STATE.indent]
    local full = ind .. _tostring(line)
    local sz = #full + 1
    if STATE.current_size + sz > CFG.MAX_OUTPUT_SIZE then
        STATE.limit_reached = true
        STATE.output[#STATE.output + 1] = "[DUMP SIZE LIMIT REACHED]"
        _error("DUMP_LIMIT_EXCEEDED", 0)
        return
    end
    if full == STATE.last_line then
        STATE.rep_count = STATE.rep_count + 1
        if STATE.rep_count <= CFG.MAX_REPEATED_LINES then
            STATE.output[#STATE.output + 1] = full
            STATE.current_size = STATE.current_size + sz
        elseif STATE.rep_count == CFG.MAX_REPEATED_LINES + 1 then
            local msg = ind .. "[...repeated suppressed]"
            STATE.output[#STATE.output + 1] = msg
            STATE.current_size = STATE.current_size + #msg
        end
    else
        STATE.last_line = full
        STATE.rep_count = 0
        STATE.output[#STATE.output + 1] = full
        STATE.current_size = STATE.current_size + sz
    end
    if CFG.VERBOSE then _print(full) end
end

local function emit_blank()
    STATE.last_line = nil
    STATE.output[#STATE.output + 1] = ""
end

local function get_output()
    return tbl_concat(STATE.output, "\n")
end

local function save_output(path)
    local f = _io.open(path or CFG.OUTPUT_FILE, "w")
    if not f then _print("[Dumper] ERROR: Cannot open output: " .. (path or CFG.OUTPUT_FILE)); return false end
    local content = get_output()
    content = str_gsub(content, "\n\n+", "\n")
    content = str_gsub(content, "^\n+", "")
    content = str_gsub(content, "\n+$", "")
    f:write(content)
    f:close()
    return true
end

local function sanitize(src)
    if _type(src) ~= "string" then return "" end
    local parts = {}
    local i, n, seg = 1, #src, 1

    local function count_eq(pos)
        local c = 0
        while pos <= n and src:byte(pos) == 61 do c = c + 1; pos = pos + 1 end
        return c, pos
    end
    local function long_close(pos, eq)
        local cl = "]" .. str_rep("=", eq) .. "]"
        local _, e = str_find(src, cl, pos, true)
        return e or n
    end
    local function xform(chunk)
        if not chunk or chunk == "" then return "" end

        chunk = str_gsub(chunk, "0[bB]([01_]+)", function(b)
            local c = str_gsub(b, "_", "")
            local v = _tonumber(c, 2)
            return v and _tostring(v) or "0"
        end)

        chunk = str_gsub(chunk, "0[xX]([%x_]+)", function(h)
            return "0x" .. str_gsub(h, "_", "")
        end)

        while str_match(chunk, "%d_%d") do
            chunk = str_gsub(chunk, "(%d)_(%d)", "%1%2")
        end

        local ops = {
            {"+=","+"}, {"-=","-"}, {"*=","*"}, {"/=","/"}, {"//=","//"},
            {"%%=","%%"}, {"%^=","^"}, {"%.%.=",".."},
        }
        for _, op in _ipairs(ops) do
            local pat, rep = op[1], op[2]

            chunk = str_gsub(chunk, "([%a_][%w_]*)%s*" .. pat,
                function(v) return v .. " = " .. v .. " " .. rep .. " " end)

            chunk = str_gsub(chunk, "([%a_][%w_]*%.[%a_][%w_%.]+)%s*" .. pat,
                function(v) return v .. " = " .. v .. " " .. rep .. " " end)
        end

        chunk = str_gsub(chunk, "([^%w_])continue([^%w_])", "%1_G.LuraphContinue()%2")
        chunk = str_gsub(chunk, "^continue([^%w_])", "_G.LuraphContinue()%1")
        chunk = str_gsub(chunk, "([^%w_])continue$", "%1_G.LuraphContinue()")

        chunk = str_gsub(chunk, ":%s*[%a_][%w_%.]*%??%s*=", " =")

        chunk = str_gsub(chunk, "^%s*export%s+type%s+", "local _type_alias_")
        chunk = str_gsub(chunk, "\nexport%s+type%s+", "\nlocal _type_alias_")
        return chunk
    end

    while i <= n do
        local b = src:byte(i)
        if b == 91 then
            local eq, np = count_eq(i + 1)
            if np <= n and src:byte(np) == 91 then
                parts[#parts+1] = xform(src:sub(seg, i - 1))
                local ce = long_close(np + 1, eq)
                parts[#parts+1] = src:sub(i, ce)
                i = ce; seg = i + 1
            end
        elseif b == 45 and i+1 <= n and src:byte(i+1) == 45 then
            parts[#parts+1] = xform(src:sub(seg, i - 1))
            if i+2 <= n and src:byte(i+2) == 91 then
                local eq, np = count_eq(i + 3)
                if np <= n and src:byte(np) == 91 then
                    local ce = long_close(np + 1, eq)
                    i = ce; seg = i + 1
                    goto _continue
                end
            end

            local nl = str_find(src, "\n", i + 2, true)
            i = nl or n; seg = i + 1
        elseif b == 34 or b == 39 or b == 96 then
            parts[#parts+1] = xform(src:sub(seg, i - 1))
            local q = b
            local ss = i
            i = i + 1
            while i <= n do
                local cb = src:byte(i)
                if cb == 92 then i = i + 1
                elseif cb == q then break end
                i = i + 1
            end
            local inner = src:sub(ss + 1, i - 1)
            if q == 96 then
                inner = str_gsub(inner, "{[^}]*}", "...")
                parts[#parts+1] = '"' .. str_gsub(inner, '"', '\\"') .. '"'
            else
                local qc = string.char(q)
                parts[#parts+1] = qc .. inner .. qc
            end
            seg = i + 1
        end
        ::_continue::
        i = i + 1
    end
    parts[#parts+1] = xform(src:sub(seg))
    return tbl_concat(parts)
end

local HOOKOP = {}

function HOOKOP.instrument(raw_src)
    local H   = CFG.HOOK_CALL_ID
    local src = raw_src
    local sn  = #src

    local T_NAME,T_NUM,T_STR,T_OP,T_KW,T_EOF = 1,2,3,4,5,6

    local KWS = {}
    for _,k in _ipairs({"and","break","do","else","elseif","end","false","for",
        "function","goto","if","in","local","nil","not","or","repeat","return",
        "then","true","until","while"}) do KWS[k] = true end

    local toks = {}
    local p    = 1

    local function is_digit(b) return b>=48 and b<=57 end
    local function is_alpha(b) return b>=65 and b<=90 or b>=97 and b<=122 or b==95 end
    local function is_alnum(b) return is_alpha(b) or is_digit(b) end

    local function scan_long(offset)
        local eq=0; local j=p+offset
        while j<=sn and src:byte(j)==61 do eq=eq+1; j=j+1 end
        if j>sn or src:byte(j)~=91 then return nil end
        local close="]"..str_rep("=",eq).."]"
        local _,e=str_find(src,close,j+1,true)
        if not e then e=sn end
        local res=src:sub(p,e); p=e+1; return res
    end

    while p<=sn do
        local ws_s=p
        while p<=sn do
            local b=src:byte(p)
            if b==32 or b==9 or b==13 or b==10 then
                p=p+1
            elseif b==45 and p+1<=sn and src:byte(p+1)==45 then
                p=p+2
                if p<=sn and src:byte(p)==91 then
                    local res=scan_long(1)
                    if not res then while p<=sn and src:byte(p)~=10 do p=p+1 end end
                else
                    while p<=sn and src:byte(p)~=10 do p=p+1 end
                end
            else break end
        end
        local ws=src:sub(ws_s,p-1)
        if p>sn then toks[#toks+1]={T_EOF,"",ws}; break end
        local b=src:byte(p)
        if b==91 then
            local sp=p; local res=scan_long(1)
            if res then toks[#toks+1]={T_STR,res,ws}; goto nxt end
            p=sp
        end
        if b==34 or b==39 then
            local q=b; local s2=p; p=p+1
            while p<=sn do
                local cb=src:byte(p)
                if cb==92 then p=p+2
                elseif cb==q then p=p+1; break
                else p=p+1 end
            end
            toks[#toks+1]={T_STR,src:sub(s2,p-1),ws}; goto nxt
        end
        if is_digit(b) or (b==46 and p+1<=sn and is_digit(src:byte(p+1))) then
            local s2=p
            if b==48 and p+1<=sn and (src:byte(p+1)==120 or src:byte(p+1)==88) then
                p=p+2; while p<=sn and is_alnum(src:byte(p)) do p=p+1 end
            else
                while p<=sn and (is_digit(src:byte(p)) or src:byte(p)==46 or
                    src:byte(p)==101 or src:byte(p)==69 or src:byte(p)==95) do p=p+1 end
            end
            toks[#toks+1]={T_NUM,src:sub(s2,p-1),ws}; goto nxt
        end
        if is_alpha(b) then
            local s2=p
            while p<=sn and is_alnum(src:byte(p)) do p=p+1 end
            local w=src:sub(s2,p-1)
            toks[#toks+1]={KWS[w] and T_KW or T_NAME,w,ws}; goto nxt
        end
        do
            local s2=p
            local b2=p+1<=sn and src:byte(p+1) or 0
            local b3=p+2<=sn and src:byte(p+2) or 0
            if b==46 and b2==46 and b3==46 then p=p+3
            elseif b==46 and b2==46 then p=p+2
            elseif (b==61 and b2==61) or (b==126 and b2==61) or
                   (b==60 and b2==61) or (b==62 and b2==61) or
                   (b==58 and b2==58) or (b==47 and b2==47) or
                   (b==60 and b2==60) or (b==62 and b2==62) then p=p+2
            else p=p+1 end
            toks[#toks+1]={T_OP,src:sub(s2,p-1),ws}
        end
        ::nxt::
    end
    if #toks==0 or toks[#toks][1]~=T_EOF then toks[#toks+1]={T_EOF,"",""} end

    local nt=toks
    local ti=1
    local out={}

    local function tv()  return nt[ti] and nt[ti][2] or "" end
    local function tt()  return nt[ti] and nt[ti][1] or T_EOF end
    local function tw()  return nt[ti] and nt[ti][3] or "" end
    local function peek_v(n2) local t=nt[ti+n2]; return t and t[2] or "" end
    local function peek_t(n2) local t=nt[ti+n2]; return t and t[1] or T_EOF end

    local function eo(s) out[#out+1]=s end

    local function take_raw()
        local t=nt[ti]; ti=ti+1
        if not t then return "" end
        return t[3]..t[2]
    end

    local function take_ws()
        local t=nt[ti]; ti=ti+1
        if not t then return "","" end
        return t[3],t[2]
    end

    local function expect_op(v)
        if tt()==T_OP and tv()==v then return take_raw() end
        return ""
    end

    local function expect_kw(v)
        if tt()==T_KW and tv()==v then return take_raw() end
        return ""
    end

    local parse_expr, parse_block, parse_stmt

    local function parse_args()
        if tt()==T_OP and tv()=="(" then
            local o=take_raw()
            if tt()==T_OP and tv()==")" then return o..take_raw() end
            local parts={o}
            local first=true
            while not (tt()==T_OP and tv()==")") and tt()~=T_EOF do
                if not first then parts[#parts+1]=take_raw() end
                first=false
                parts[#parts+1]=parse_expr()
            end
            parts[#parts+1]=expect_op(")")
            return table.concat(parts)
        elseif tt()==T_STR then
            return take_raw()
        elseif tt()==T_OP and tv()=="{" then
            return parse_table_constructor()
        end
        return ""
    end

    local function parse_table_constructor()
        local o=expect_op("{")
        local parts={o}
        while not (tt()==T_OP and tv()=="}") and tt()~=T_EOF do
            if tt()==T_OP and (tv()=="," or tv()==";") then
                parts[#parts+1]=take_raw()
            elseif tt()==T_NAME and peek_v(1)=="=" then
                parts[#parts+1]=take_raw()
                parts[#parts+1]=take_raw()
                parts[#parts+1]=parse_expr()
            elseif tt()==T_OP and tv()=="[" then
                parts[#parts+1]=take_raw()
                parts[#parts+1]=parse_expr()
                parts[#parts+1]=expect_op("]")
                parts[#parts+1]=expect_op("=")
                parts[#parts+1]=parse_expr()
            else
                parts[#parts+1]=parse_expr()
            end
        end
        parts[#parts+1]=expect_op("}")
        return table.concat(parts)
    end

    local function parse_fn_params_and_body()
        local parts={}
        parts[#parts+1]=expect_op("(")
        while not (tt()==T_OP and tv()==")") and tt()~=T_EOF do
            if tt()==T_OP and tv()=="," then parts[#parts+1]=take_raw()
            elseif tt()==T_OP and tv()=="..." then parts[#parts+1]=take_raw()
            elseif tt()==T_NAME then parts[#parts+1]=take_raw()
            else break end
        end
        parts[#parts+1]=expect_op(")")
        parts[#parts+1]=parse_block()
        parts[#parts+1]=expect_kw("end")
        return table.concat(parts)
    end

    local function parse_primary()
        if tt()==T_NAME then
            return take_raw()
        elseif tt()==T_KW and (tv()=="true" or tv()=="false" or tv()=="nil" or tv()=="...") then
            return take_raw()
        elseif tt()==T_NUM then
            return take_raw()
        elseif tt()==T_STR then
            return take_raw()
        elseif tt()==T_OP and tv()=="(" then
            local o=take_raw()
            local e=parse_expr()
            local c=expect_op(")")
            return o..e..c
        elseif tt()==T_OP and tv()=="{" then
            return parse_table_constructor()
        elseif tt()==T_KW and tv()=="function" then
            local o=take_raw()
            return o..parse_fn_params_and_body()
        end
        if tt()==T_KW then
            return tw()
        end
        if tt()==T_EOF then return "" end
        return take_raw()
    end

    local function parse_suffixed_expr(no_wrap_call)
        local base=parse_primary()
        while true do
            if tt()==T_OP and tv()=="." then
                local dot_ws,dot_v=take_ws()
                if tt()==T_NAME then
                    local fw,fv=take_ws()
                    local field=fw..fv
                    if tt()==T_OP and (tv()=="(" or tv()=="{") or tt()==T_STR then
                        local args=parse_args()
                        if no_wrap_call then
                            base=base..dot_ws..dot_v..field..args
                        else
                            local inner=args:match("^%((.*)%)$"); if inner==nil then inner=args end
                            local ws=base:match("^%s*") or ""; local b=base:sub(#ws+1)
                            if inner=="" then base=ws..H.."CALL("..b..dot_ws..dot_v..field..")"
                            else              base=ws..H.."CALL("..b..dot_ws..dot_v..field..","..inner..")" end
                        end
                    elseif tt()==T_OP and tv()==":" then
                        base=base..dot_ws..dot_v..field
                    else
                        if no_wrap_call then
                            base=base..dot_ws..dot_v..field
                        else
                            local ws=base:match("^%s*") or ""; local b=base:sub(#ws+1)
                            base=ws..H.."CHECKINDEX("..b..","..str_format("%q",fv)..")"
                        end
                    end
                else
                    base=base..dot_ws..dot_v
                end
            elseif tt()==T_OP and tv()==":" then
                local colon_ws,_=take_ws()
                if tt()==T_NAME then
                    local mw,mv=take_ws()
                    if tt()==T_OP and (tv()=="(" or tv()=="{") or tt()==T_STR then
                        local args=parse_args()
                        local body
                        if args:sub(1,1)=="(" and args:sub(-1)==")" then body=args:sub(2,-2) else body=args end
                        local ws=base:match("^%s*") or ""; local b=base:sub(#ws+1)
                        if body=="" then base=ws..H.."NAMECALL("..b..","..str_format("%q",mv)..")"
                        else             base=ws..H.."NAMECALL("..b..","..str_format("%q",mv)..","..body..")" end
                    else
                        base=base..colon_ws..":"..mw..mv
                    end
                else
                    base=base..colon_ws..":"
                end
            elseif tt()==T_OP and tv()=="[" then
                local brk_ws,_=take_ws()
                local idx=parse_expr()
                local rc=expect_op("]")
                if tt()==T_OP and (tv()=="(" or tv()=="{") or tt()==T_STR then
                    local args=parse_args()
                    if no_wrap_call then
                        base=base..brk_ws.."["..idx..rc..args
                    else
                        local inner=args:match("^%((.*)%)$"); if inner==nil then inner=args end
                        local ws=base:match("^%s*") or ""; local b=base:sub(#ws+1)
                        if inner=="" then base=ws..H.."CALL("..H.."CHECKINDEX("..b..","..idx..")"
                        else              base=ws..H.."CALL("..H.."CHECKINDEX("..b..","..idx.."),"..inner..")" end
                    end
                else
                    if no_wrap_call then
                        base=base..brk_ws.."["..idx..rc
                    else
                        local ws=base:match("^%s*") or ""; local b=base:sub(#ws+1)
                        base=ws..H.."CHECKINDEX("..b..","..idx..")"
                    end
                end
            elseif tt()==T_OP and (tv()=="(" or tv()=="{") or tt()==T_STR then
                local args=parse_args()
                if no_wrap_call then
                    base=base..args
                else
                    local inner=args:match("^%((.*)%)$"); if inner==nil then inner=args end
                    local ws=base:match("^%s*") or ""; local b=base:sub(#ws+1)
                    if inner=="" then base=ws..H.."CALL("..b..")"
                    else              base=ws..H.."CALL("..b..","..inner..")" end
                end
            else
                break
            end
        end
        return base
    end
    local UNARY_OPS={["not"]=H.."CHECKNOT",["#"]=H.."CHECKLEN",["-"]=H.."CHECKUNM"}

    local function parse_unary()
        if tt()==T_KW and (tv()=="not") then
            local ws_u,op_u=take_ws()
            local e=parse_unary()
            return ws_u..H.."CHECKNOT("..e:gsub("^%s+","")..")"
        elseif tt()==T_OP and tv()=="#" then
            local ws_u,_=take_ws()
            local e=parse_unary()
            return ws_u..H.."CHECKLEN("..e:gsub("^%s+","")..")"
        elseif tt()==T_OP and tv()=="-" then
            local prev_type=tt()
            local ws_u,_=take_ws()
            local e=parse_unary()
            return ws_u..H.."CHECKUNM("..e:gsub("^%s+","")..")"
        else
            return parse_suffixed_expr(false)
        end
    end

    local function parse_pow()
        local base=parse_unary()
        while tt()==T_OP and tv()=="^" do
            local ow,ov=take_ws()
            local r=parse_unary()
            base="("..base..ow..ov..r..")"
        end
        return base
    end

    local function parse_mul()
        local base=parse_pow()
        while tt()==T_OP and (tv()=="*" or tv()=="/" or tv()=="%" or tv()=="//") do
            local ow,ov=take_ws()
            local r=parse_pow()
            base="("..base..ow..ov..r..")"
        end
        return base
    end

    local function parse_add()
        local base=parse_mul()
        while tt()==T_OP and (tv()=="+" or tv()=="-") do
            local ow,ov=take_ws()
            local r=parse_mul()
            base="("..base..ow..ov..r..")"
        end
        return base
    end

    local CMP_NAME={[">"]=H.."COMPG",["<"]=H.."COMPL",
        [">="]=H.."COMPGE",["<="]=H.."COMPLE",
        ["=="]=H.."CHECKEQ",["~="]=H.."CHECKNEQ"}

    local function parse_cat()
        local base=parse_add()
        while tt()==T_OP and tv()==".." do
            local ow,ov=take_ws()
            local r=parse_add()
            base=H.."CONCAT("..base:gsub("^%s+","")..","..r:gsub("^%s+","")..")"
        end
        return base
    end

    local function parse_cmp()
        local base=parse_cat()
        while tt()==T_OP and CMP_NAME[tv()] do
            local ow,ov=take_ws()
            local fn_name=CMP_NAME[ov]
            local r=parse_cat()
            base=ow..fn_name.."("..base:gsub("^%s+","")..","..r:gsub("^%s+","")..")"
        end
        return base
    end

    local function parse_and()
        local base=parse_cmp()
        while tt()==T_KW and tv()=="and" do
            local ow,_=take_ws()
            local r=parse_cmp()
            local rhs_str=r:gsub("^%s+","")
            local is_fn="false"
            if rhs_str:find("^"..H) or rhs_str:sub(1,1)=="(" then is_fn="false" end
            base=ow..H.."CHECKAND("..base:gsub("^%s+","")..",function() return "..rhs_str.." end,true)"
        end
        return base
    end

    local function parse_or()
        local base=parse_and()
        while tt()==T_KW and tv()=="or" do
            local ow,_=take_ws()
            local r=parse_and()
            local rhs_str=r:gsub("^%s+","")
            base=ow..H.."CHECKOR("..base:gsub("^%s+","")..",function() return "..rhs_str.." end,true)"
        end
        return base
    end

    parse_expr = parse_or

    local function parse_exprlist()
        local parts={parse_expr()}
        while tt()==T_OP and tv()=="," do
            parts[#parts+1]=take_raw()
            parts[#parts+1]=parse_expr()
        end
        return table.concat(parts)
    end

    local function skip_name_chain()
        local parts={}
        if tt()==T_NAME then parts[#parts+1]=take_raw()
        elseif tt()==T_KW then parts[#parts+1]=take_raw()
        else return "" end
        while tt()==T_OP and tv()=="." do
            parts[#parts+1]=take_raw()
            if tt()==T_NAME or tt()==T_KW then parts[#parts+1]=take_raw() end
        end
        return table.concat(parts)
    end

    local function parse_lhs_list()
        local parts={}
        parts[#parts+1]=parse_suffixed_expr(true)
        while tt()==T_OP and tv()=="," do
            parts[#parts+1]=take_raw()
            parts[#parts+1]=parse_suffixed_expr(true)
        end
        return table.concat(parts)
    end

    parse_stmt = function()
        if tt()==T_EOF then return "" end
        local t=tv()
        local tk=tt()

        if tk==T_OP and (t==";" or t==",") then return take_raw() end

        if tk==T_KW and t=="local" then
            local o=take_raw()
            if tt()==T_KW and tv()=="function" then
                local kw=take_raw()
                local nm=tt()==T_NAME and take_raw() or ""
                return o..kw..nm..parse_fn_params_and_body()
            end
            local names={}
            while tt()==T_NAME do
                names[#names+1]=take_raw()
                if tt()==T_OP and tv()=="," then names[#names+1]=take_raw() else break end
            end
            local rest=""
            if tt()==T_OP and tv()=="=" then
                rest=take_raw()..parse_exprlist()
            end
            return o..table.concat(names)..rest
        end

        if tk==T_KW and t=="function" then
            local o=take_raw()
            local nm=skip_name_chain()
            local colon=""
            if tt()==T_OP and tv()==":" then
                colon=take_raw()
                nm=nm..colon..(tt()==T_NAME and take_raw() or "")
            end
            return o..nm..parse_fn_params_and_body()
        end

        if tk==T_KW and t=="return" then
            local o=take_raw()
            if tt()==T_KW and (tv()=="end" or tv()=="until" or tv()=="else" or tv()=="elseif") then
                return o
            end
            if tt()==T_OP and (tv()==";" or tv()==")") then return o end
            if tt()==T_EOF then return o end
            return o..parse_exprlist()
        end

        if tk==T_KW and t=="do" then
            local o=take_raw()..parse_block()..expect_kw("end")
            return o
        end

        if tk==T_KW and t=="while" then
            local o=take_raw()
            local cond=parse_expr()
            local do_kw=expect_kw("do")
            local body=parse_block()
            local end_kw=expect_kw("end")
            return o..cond..do_kw..body..end_kw
        end

        if tk==T_KW and t=="if" then
            local parts={take_raw(), parse_expr(), expect_kw("then"), parse_block()}
            while tt()==T_KW and tv()=="elseif" do
                parts[#parts+1]=take_raw()
                parts[#parts+1]=parse_expr()
                parts[#parts+1]=expect_kw("then")
                parts[#parts+1]=parse_block()
            end
            if tt()==T_KW and tv()=="else" then
                parts[#parts+1]=take_raw()
                parts[#parts+1]=parse_block()
            end
            parts[#parts+1]=expect_kw("end")
            return table.concat(parts)
        end

        if tk==T_KW and t=="for" then
            local o=take_raw()
            if tt()==T_NAME and peek_v(1)=="=" then
                local var=take_raw()
                local eq=take_raw()
                local from=parse_expr()
                local comma1=expect_op(",")
                local to=parse_expr()
                local step=""
                if tt()==T_OP and tv()=="," then step=take_raw()..parse_expr() end
                local do_kw=expect_kw("do")
                local body=parse_block()
                local end_kw=expect_kw("end")
                return o..var..eq..from..comma1..to..step..do_kw..body..end_kw
            else
                local vars={}
                while tt()==T_NAME do
                    vars[#vars+1]=take_raw()
                    if tt()==T_OP and tv()=="," then vars[#vars+1]=take_raw() else break end
                end
                local in_kw=expect_kw("in")
                local iters=parse_exprlist()
                local do_kw=expect_kw("do")
                local body=parse_block()
                local end_kw=expect_kw("end")
                return o..table.concat(vars)..in_kw..iters..do_kw..body..end_kw
            end
        end

        if tk==T_KW and t=="repeat" then
            local o=take_raw()..parse_block()
            local u=expect_kw("until")
            local cond=parse_expr()
            return o..u..cond
        end

        if tk==T_KW and t=="goto" then return take_raw()..(tt()==T_NAME and take_raw() or "") end
        if tk==T_KW and t=="break" then return take_raw() end

        if tk==T_OP and t=="::" then
            local o=take_raw()
            local nm=tt()==T_NAME and take_raw() or ""
            local c=tt()==T_OP and tv()=="::" and take_raw() or ""
            return o..nm..c
        end

        local expr=parse_suffixed_expr(false)
        if tt()==T_OP and tv()=="," then
            local more={expr}
            while tt()==T_OP and tv()=="," do
                more[#more+1]=take_raw()
                more[#more+1]=parse_suffixed_expr(true)
            end
            local lhs=table.concat(more)
            if tt()==T_OP and tv()=="=" then
                local eq=take_raw()
                local rhs=parse_exprlist()
                return lhs..eq..rhs
            end
            return lhs
        end
        if tt()==T_OP and tv()=="=" then
            local eq=take_raw()
            local rhs=parse_exprlist()
            return expr..eq..rhs
        end
        return expr
    end

    parse_block = function()
        local parts={}
        while tt()~=T_EOF do
            local t=tv(); local tk=tt()
            if tk==T_KW and (t=="end" or t=="else" or t=="elseif" or t=="until" or t=="then") then break end
            local s=parse_stmt()
            if s~="" then parts[#parts+1]=s end
        end
        return table.concat(parts)
    end

    local result=parse_block()
    while ti<=#toks do result=result..take_raw() end
    return result
end

function HOOKOP.make_hooks()
    local ID  = CFG.HOOK_CALL_ID
    local hooks = {}

    hooks[ID.."CALL"] = function(fn, ...)
        if _type(fn) ~= "function" and not is_proxy(fn) then return nil end
        local r = table.pack(_pcall(fn, ...))
        if r[1] then return table.unpack(r, 2, r.n) end
        return nil
    end

    hooks[ID.."NAMECALL"] = function(obj, method, ...)
        if obj == nil then return nil end
        local ok2, fn = _pcall(function() return obj[method] end)
        if not ok2 or fn == nil then return nil end
        if is_proxy(fn) or _type(fn) == "function" then
            local r = table.pack(_pcall(fn, obj, ...))
            if r[1] then return table.unpack(r, 2, r.n) end
        end
        return nil
    end

    hooks[ID.."CHECKINDEX"] = function(obj, key)
        if obj == nil then return nil end
        local ok2, v = _pcall(function() return obj[key] end)
        return ok2 and v or nil
    end

    hooks[ID.."CONSTRUCT"] = function(t) return t end
    hooks[ID.."GET"]       = function(v) return v end

    hooks[ID.."CHECKAND"] = function(a, b_fn, is_fn, ...)
        if a then return is_fn and b_fn(...) or b_fn end
        return a
    end
    hooks[ID.."CHECKOR"] = function(a, b_fn, is_fn, ...)
        if a then return a end
        return is_fn and b_fn(...) or b_fn
    end

    hooks[ID.."COMPG"]   = function(a,b) local ok2,v=_pcall(function() return a> b end); return ok2 and v or false end
    hooks[ID.."COMPL"]   = function(a,b) local ok2,v=_pcall(function() return a< b end); return ok2 and v or false end
    hooks[ID.."COMPGE"]  = function(a,b) local ok2,v=_pcall(function() return a>=b end); return ok2 and v or false end
    hooks[ID.."COMPLE"]  = function(a,b) local ok2,v=_pcall(function() return a<=b end); return ok2 and v or false end
    hooks[ID.."CHECKEQ"] = function(a,b) local ok2,v=_pcall(function() return a==b end); return ok2 and v or false end
    hooks[ID.."CHECKNEQ"]= function(a,b) local ok2,v=_pcall(function() return a~=b end); return ok2 and v or true  end

    hooks[ID.."CHECKLEN"] = function(v)
        if _type(v)=="string" or _type(v)=="table" then
            local ok2,r=_pcall(function() return #v end); return ok2 and r or 0
        end
        return 0
    end
    hooks[ID.."CHECKUNM"] = function(v)
        if is_num_proxy(v) then return -(rawget(v,"__value") or 0) end
        local ok2,r=_pcall(function() return -v end); return ok2 and r or 0
    end
    hooks[ID.."CHECKNOT"] = function(v) return not v end

    hooks[ID.."CONCAT"] = function(a, b)
        if not is_proxy(a) and not is_proxy(b) then
            local ok2,r=_pcall(function() return a..b end); if ok2 then return r end
        end
        local as=is_proxy(a) and (STATE.registry[a] or "obj") or _tostring(a)
        local bs=is_proxy(b) and (STATE.registry[b] or "obj") or _tostring(b)
        return as..bs
    end

    hooks[ID.."TEMPLATE_STRING"] = function(fmt, ...)
        local args={...}; local res={}
        for _,v in _ipairs(args) do
            res[#res+1]=is_proxy(v) and (STATE.registry[v] or "obj") or _tostring(v)
        end
        local ok2,r=_pcall(str_format,fmt,_unpack(res)); return ok2 and r or fmt
    end

    hooks[ID.."CHECKIF"]      = function(cond) return cond end
    hooks[ID.."checkifend"]   = function() end
    hooks[ID.."checkwhile"]   = function(cond) return cond end
    hooks[ID.."checkwhileend"]= function() end

    local _fi={}
    hooks[ID.."FORINFO"]  = function(id,from,to,step) _fi[id]={from=from,to=to,step=step or 1} end
    hooks[ID.."FORSTEP1"] = function(id) return _fi[id] and _fi[id].from or 1 end
    hooks[ID.."FORSTEP2"] = function(id) return _fi[id] and _fi[id].to   or 0 end

    return hooks
end

local serialize

serialize = function(val, depth, seen, inline)
    depth = depth or 0
    seen  = seen  or {}
    if depth > CFG.MAX_DEPTH then return "{ }" end

    if is_num_proxy(val) then
        return _tostring(rawget(val, "__value") or 0)
    end

    local vt = _type(val)

    if vt == "table" and STATE.registry[val] then
        return STATE.registry[val]
    end

    if vt == "nil"     then return "nil" end
    if vt == "boolean" then return _tostring(val) end

    if vt == "string" then

        if #val > 80 and val:match("^[A-Za-z0-9+/=]+$") then
            STATE.string_refs[#STATE.string_refs+1] = {value=val:sub(1,60).."...", hint="base64", len=#val}
        elseif val:match("https?://") then
            STATE.string_refs[#STATE.string_refs+1] = {value=val, hint="URL"}
        elseif val:match("rbxasset[id]*://") then
            STATE.string_refs[#STATE.string_refs+1] = {value=val, hint="Asset"}
        end

        local e = str_gsub(val, "\\", "\\\\")
        e = str_gsub(e, '"',  '\\"')
        e = str_gsub(e, "\n", "\\n")
        e = str_gsub(e, "\r", "\\r")
        e = str_gsub(e, "\t", "\\t")
        e = str_gsub(e, "%z", "\\0")
        return '"' .. e .. '"'
    end

    if vt == "number" then
        if val ~= val        then return "0/0" end
        if val ==  math_huge then return "math.huge" end
        if val == -math_huge then return "-math.huge" end
        if val == math_floor(val) then return _tostring(math_floor(val)) end
        return str_format("%.10g", val)
    end

    if vt == "function" then return STATE.registry[val] or "function() end" end
    if vt == "thread"   then return "coroutine.create(function() end)" end

    if vt == "userdata" then
        local r = STATE.registry[val]
        if r then return r end
        local ok, s = _pcall(_tostring, val)
        return ok and s or "userdata"
    end

    if vt == "table" then
        if is_proxy(val) then return STATE.registry[val] or "proxy" end
        if seen[val]     then return "{ }" end
        seen[val] = true

        local count = 0
        for k in _pairs(val) do
            if k ~= PROXY_SEN and k ~= "__proxy_id" and k ~= NUMPROX_SEN and k ~= "__value" then
                count = count + 1
            end
        end
        if count == 0 then seen[val] = nil; return "{}" end

        local is_arr = true; local max_i = 0
        for k in _pairs(val) do
            if k ~= PROXY_SEN and k ~= "__proxy_id" and k ~= NUMPROX_SEN and k ~= "__value" then
                if _type(k) ~= "number" or k < 1 or k ~= math_floor(k) then
                    is_arr = false; break
                elseif k > max_i then max_i = k end
            end
        end
        is_arr = is_arr and max_i == count

        if is_arr and count <= 12 and inline ~= false then
            local items = {}; local ok_arr = true
            for i2 = 1, count do
                local v = val[i2]
                if _type(v) == "table" and not is_proxy(v) then ok_arr = false; break end
                items[i2] = serialize(v, depth+1, seen, true)
            end
            if ok_arr and #items == count then
                seen[val] = nil
                return "{" .. tbl_concat(items, ", ") .. "}"
            end
        end

        local parts = {}
        local ni     = (STATE.indent or 0) + depth
        local ind_in = INDENT_CACHE[ni + 1]
        local ind_out = INDENT_CACHE[ni]
        local n2 = 0
        for k, v in _pairs(val) do
            if k ~= PROXY_SEN and k ~= "__proxy_id" and k ~= NUMPROX_SEN and k ~= "__value" then
                n2 = n2 + 1
                if n2 > CFG.MAX_TABLE_ITEMS then
                    parts[#parts+1] = ind_in .. string.format("..%d more..", count - n2 + 1)
                    break
                end
                local ks
                if is_arr then ks = nil
                elseif _type(k) == "string" and k:match("^[%a_][%w_]*$") then ks = k
                else ks = "[" .. serialize(k, depth+1, seen) .. "]" end
                local vs = serialize(v, depth+1, seen)
                parts[#parts+1] = ks and (ind_in .. ks .. " = " .. vs) or (ind_in .. vs)
            end
        end
        seen[val] = nil
        if #parts == 0 then return "{}" end
        return "{\n" .. tbl_concat(parts, ",\n") .. "\n" .. ind_out .. "}"
    end

    local ok, s = _pcall(_tostring, val)
    return ok and s or "nil"
end

local function name_of(v)
    if v == nil then return "nil" end
    local t = _type(v)
    if t == "string" then return v end
    if t == "number" or t == "boolean" then return _tostring(v) end
    if t == "table" then
        if STATE.registry[v] then return STATE.registry[v] end
        if is_proxy(v) then
            local pid = rawget(v, "__proxy_id")
            return pid and "proxy_"..pid or "proxy"
        end
    end
    local ok, s = _pcall(_tostring, v)
    return ok and s or "unknown"
end

local function quote(v)
    local s = name_of(v)
    local e = str_gsub(s, "\\", "\\\\")
    e = str_gsub(e, '"',  '\\"')
    e = str_gsub(e, "\n", "\\n")
    e = str_gsub(e, "\r", "\\r")
    e = str_gsub(e, "\t", "\\t")
    return '"' .. e .. '"'
end

local function new_var(is_fn)
    if is_fn then
        STATE.func_counter = STATE.func_counter + 1
        return "fn" .. STATE.func_counter
    end
    STATE.var_counter = STATE.var_counter + 1
    return "v" .. STATE.var_counter
end

local function reg_proxy(proxy, hint, type_hint)
    local ex = STATE.registry[proxy]
    if ex then return ex end
    STATE.lar_counter = STATE.lar_counter + 1
    local nm = "lar" .. STATE.lar_counter
    STATE.names_used[nm] = true
    STATE.registry[proxy] = nm
    STATE.reverse_registry[nm] = proxy
    STATE.variable_types[nm] = type_hint or _type(proxy)
    return nm
end

local function make_num_proxy(val)
    local p = {}; local m = {}
    PROXY_SEN[p] = true
    setmetatable(p, m)
    rawset(p, NUMPROX_SEN, true)
    rawset(p, "__value", val)
    STATE.registry[p] = _tostring(val)
    m.__tostring = function() return _tostring(val) end
    m.__index = function(_, k)
        if k == NUMPROX_SEN or k == "__proxy_id" or k == "__value" then return rawget(p, k) end
        return make_num_proxy(0)
    end
    m.__newindex = function() end
    m.__call = function() return val end
    local function mk_op(op)
        return function(a, b)
            local av = _type(a)=="table" and rawget(a,"__value") or (a or 0)
            local bv = _type(b)=="table" and rawget(b,"__value") or (b or 0)
            local r
            if     op=="+" then r=av+bv
            elseif op=="-" then r=av-bv
            elseif op=="*" then r=av*bv
            elseif op=="/" then r=bv~=0 and av/bv or 0
            elseif op=="%" then r=bv~=0 and av%bv or 0
            elseif op=="^" then r=av^bv
            elseif op=="//" then r=bv~=0 and math_floor(av/bv) or 0
            else r=0 end
            return make_num_proxy(r)
        end
    end
    m.__add=mk_op("+"); m.__sub=mk_op("-"); m.__mul=mk_op("*")
    m.__div=mk_op("/"); m.__mod=mk_op("%"); m.__pow=mk_op("^")
    m.__idiv=mk_op("//")
    m.__unm=function(a) return make_num_proxy(-(rawget(a,"__value") or 0)) end
    m.__eq=function(a,b)
        local av=_type(a)=="table" and rawget(a,"__value") or a
        local bv=_type(b)=="table" and rawget(b,"__value") or b
        return av==bv
    end
    m.__lt=function(a,b)
        local av=_type(a)=="table" and rawget(a,"__value") or a
        local bv=_type(b)=="table" and rawget(b,"__value") or b
        local ok,r=_pcall(function() return av<bv end)
        return ok and r or false
    end
    m.__le=function(a,b)
        local av=_type(a)=="table" and rawget(a,"__value") or a
        local bv=_type(b)=="table" and rawget(b,"__value") or b
        local ok,r=_pcall(function() return av<=bv end)
        return ok and r or false
    end
    m.__len=function() return 0 end
    m.__concat=function(a,b)
        local as=is_num_proxy(a) and _tostring(rawget(a,"__value")) or _tostring(a)
        local bs=is_num_proxy(b) and _tostring(rawget(b,"__value")) or _tostring(b)
        return as..bs
    end
    return p
end

local function capture_call(fn, args)
    if _type(fn) ~= "function" then return {} end
    local snap = #STATE.output
    local saved = STATE.pending_iterator
    STATE.pending_iterator = false
    _xpcall(function() fn(_unpack(args or {})) end, function() end)
    while STATE.pending_iterator do
        STATE.indent = STATE.indent - 1
        emit("end")
        STATE.pending_iterator = false
    end
    STATE.pending_iterator = saved
    local cap = {}
    for i2 = snap+1, #STATE.output do cap[#cap+1] = STATE.output[i2] end
    for i2 = #STATE.output, snap+1, -1 do STATE.output[i2] = nil end
    return cap
end

local function make_arith_proxy(op)
    local function mk(lhs, rhs)
        local p = {}; local m = {}
        PROXY_SEN[p] = true
        setmetatable(p, m)
        local ls = _type(lhs)=="table" and (STATE.registry[lhs] or serialize(lhs)) or serialize(lhs)
        local rs = _type(rhs)=="table" and (STATE.registry[rhs] or serialize(rhs)) or serialize(rhs)
        local expr = "("..ls.." "..op.." "..rs..")"
        STATE.registry[p] = expr
        m.__tostring = function() return expr end
        m.__call = function() return p end
        m.__index = function(_, k)
            if k==PROXY_SEN or k=="__proxy_id" then return rawget(p,k) end
            local make_proxy = _G._DUMPER_make_proxy
            return make_proxy and make_proxy(expr.."."..name_of(k), false) or nil
        end
        local function sub_arith(op2) return make_arith_proxy(op2) end
        m.__add=sub_arith("+"); m.__sub=sub_arith("-"); m.__mul=sub_arith("*")
        m.__div=sub_arith("/"); m.__mod=sub_arith("%"); m.__pow=sub_arith("^")
        m.__concat=sub_arith("..")
        m.__eq=function() return false end
        m.__lt=function() return false end
        m.__le=function() return false end
        m.__unm=function(a)
            local q={}; local qm={}
            PROXY_SEN[q]=true; setmetatable(q,qm)
            local ex2="(-"..(STATE.registry[a] or serialize(a))..")"
            STATE.registry[q]=ex2
            qm.__tostring=function() return ex2 end
            return q
        end
        m.__len=function() return 0 end
        return p
    end
    return mk
end

local SERVICE_VAR_NAMES = {
    Players="Players", UserInputService="UserInputService",
    RunService="RunService", ReplicatedStorage="ReplicatedStorage",
    TweenService="TweenService", Workspace="Workspace",
    Lighting="Lighting", StarterGui="StarterGui", CoreGui="CoreGui",
    HttpService="HttpService", MarketplaceService="MarketplaceService",
    DataStoreService="DataStoreService", TeleportService="TeleportService",
    SoundService="SoundService", Chat="Chat", Teams="Teams",
    ProximityPromptService="ProximityPromptService",
    ContextActionService="ContextActionService",
    CollectionService="CollectionService",
    PathfindingService="PathfindingService", Debris="Debris",
    TextService="TextService", TextChatService="TextChatService",
    VRService="VRService", HapticService="HapticService",
    GuiService="GuiService", PhysicsService="PhysicsService",
    ContentProvider="ContentProvider", InsertService="InsertService",
    MessagingService="MessagingService", BadgeService="BadgeService",
    GroupService="GroupService", LocalizationService="LocalizationService",
    ServerStorage="ServerStorage", ServerScriptService="ServerScriptService",
    StarterPack="StarterPack", StarterPlayer="StarterPlayer",
}

local UI_PATS = {
    {p="window",px="Window"}, {p="tab",px="Tab"}, {p="section",px="Section"},
    {p="button",px="Button"}, {p="toggle",px="Toggle"}, {p="slider",px="Slider"},
    {p="dropdown",px="Dropdown"}, {p="textbox",px="Textbox"}, {p="input",px="Input"},
    {p="label",px="Label"}, {p="keybind",px="Keybind"}, {p="colorpicker",px="ColorPicker"},
    {p="paragraph",px="Para"}, {p="notification",px="Notif"},
    {p="divider",px="Divider"}, {p="bind",px="Bind"}, {p="picker",px="Picker"},
    {p="image",px="Image"}, {p="separator",px="Separator"},
}

local NUM_PROPS = {
    Health=100, MaxHealth=100, WalkSpeed=16, JumpPower=50, JumpHeight=7.2,
    HipHeight=2, Transparency=0, Mass=1, Value=0, TimePosition=0, TimeLength=1,
    Volume=0.5, PlaybackSpeed=1, Brightness=1, Range=60, Angle=90,
    FieldOfView=70, TextSize=14, ZIndex=1, LayoutOrder=0, Thickness=1,
    Size=1, ShadowIntensity=0.7, ClockTime=14, FogEnd=100000,
}

local BOOL_PROPS = {
    Visible=true, Enabled=true, Anchored=false, CanCollide=true, Locked=false,
    Active=true, Draggable=false, Modal=false, Playing=false, Looped=false,
    IsPlaying=false, AutoPlay=false, Archivable=true, ClipsDescendants=false,
    RichText=false, TextWrapped=false, TextScaled=false, PlatformStand=false,
    AutoRotate=true, Sit=false, ResetOnSpawn=true, RequiresNeck=true,
    CastShadow=true, RootPriority=false,
}

local BODY_PARTS = {
    Head=1, Torso=1, UpperTorso=1, LowerTorso=1,
    RightArm=1, LeftArm=1, RightLeg=1, LeftLeg=1,
    RightHand=1, LeftHand=1, RightFoot=1, LeftFoot=1,
    RightUpperArm=1, LeftUpperArm=1, RightLowerArm=1, LeftLowerArm=1,
    RightUpperLeg=1, LeftUpperLeg=1, RightLowerLeg=1, LeftLowerLeg=1,
}

local make_instance_proxy
local make_method_proxy

make_method_proxy = function(method_name, parent_proxy)
    local p = {}; local m = {}
    PROXY_SEN[p] = true
    setmetatable(p, m)
    local parent_name = STATE.registry[parent_proxy] or "object"
    STATE.registry[p] = parent_name .. "." .. method_name
    m.__call = function(self, first, ...)
        local args_list
        if first == p or first == parent_proxy or (is_proxy(first) and first ~= p) then
            args_list = {...}
        else
            args_list = {first, ...}
        end
        local method_lower = method_name:lower()
        local prefix = nil
        for _, ui in _ipairs(UI_PATS) do
            if method_lower:find(ui.p) then prefix = ui.px; break end
        end
        local cb_fn, cb_key, cb_arg_idx = nil, nil, nil
        for i2, arg in _ipairs(args_list) do
            if _type(arg) == "function" then
                cb_fn = arg; break
            elseif _type(arg) == "table" and not is_proxy(arg) then
                for k, v in _pairs(arg) do
                    if (_tostring(k)):lower() == "callback" and _type(v) == "function" then
                        cb_fn = v; cb_key = k; cb_arg_idx = i2; break
                    end
                end
            end
        end
        local cb_param = "value"; local cb_args = {}
        if cb_fn then
            if method_lower:match("toggle")  then cb_param="enabled";  cb_args={true}
            elseif method_lower:match("slider") then cb_param="value"; cb_args={50}
            elseif method_lower:match("dropdown") then cb_param="selected"; cb_args={"Option"}
            elseif method_lower:match("textbox") or method_lower:match("input") then
                cb_param="text"; cb_args={INPUT_KEY or "input"}
            elseif method_lower:match("keybind") or method_lower:match("bind") then
                cb_param="key"; cb_args={make_instance_proxy("Enum.KeyCode.E", false)}
            elseif method_lower:match("color") then
                cb_param="color"
                cb_args={Color3 and Color3.fromRGB(255,255,255) or make_instance_proxy("Color3",false)}
            elseif method_lower:match("button") then cb_param=""; cb_args={}
            end
        end
        local captured = cb_fn and capture_call(cb_fn, cb_args) or {}
        local child = make_instance_proxy(prefix or method_name, false, parent_proxy)
        local var_name = reg_proxy(child, prefix or method_name)
        local arg_strs = {}
        for i2, arg in _ipairs(args_list) do
            if _type(arg)=="table" and not is_proxy(arg) and i2==cb_arg_idx then
                local fields={}
                for k, v in _pairs(arg) do
                    local ks = _type(k)=="string" and k:match("^[%a_][%w_]*$") and k or ("["..serialize(k).."]")
                    if k == cb_key and #captured > 0 then
                        local hdr = cb_param~="" and ("function("..cb_param..")") or "function()"
                        local ind = INDENT_CACHE[STATE.indent+2]
                        local body={}
                        for _, ln in _ipairs(captured) do body[#body+1]=ind..(ln:match("^%s*(.*)$") or ln) end
                        fields[#fields+1]=ks.." = "..hdr.."\n"..tbl_concat(body,"\n").."\n"..INDENT_CACHE[STATE.indent+1].."end"
                    elseif k == cb_key then
                        fields[#fields+1]=ks.." = "..(cb_param~="" and "function("..cb_param..") end" or "function() end")
                    else
                        fields[#fields+1]=ks.." = "..serialize(v)
                    end
                end
                arg_strs[#arg_strs+1]="{\n"..INDENT_CACHE[STATE.indent+1]..tbl_concat(fields,",\n"..INDENT_CACHE[STATE.indent+1]).."\n"..INDENT_CACHE[STATE.indent].."}"
            elseif _type(arg) == "function" then
                if #captured > 0 then
                    local hdr=cb_param~="" and ("function("..cb_param..")") or "function()"
                    local ind=INDENT_CACHE[STATE.indent+1]
                    local body={}
                    for _, ln in _ipairs(captured) do body[#body+1]=ind..(ln:match("^%s*(.*)$") or ln) end
                    arg_strs[#arg_strs+1]=hdr.."\n"..tbl_concat(body,"\n").."\n"..INDENT_CACHE[STATE.indent].."end"
                else
                    arg_strs[#arg_strs+1]=cb_param~="" and ("function("..cb_param..") end") or "function() end"
                end
            else
                arg_strs[#arg_strs+1] = serialize(arg)
            end
        end
        emit(str_format("local %s = %s:%s(%s)", var_name, parent_name, method_name, tbl_concat(arg_strs,", ")))
        return child
    end
    m.__index = function(_, k)
        if k==PROXY_SEN or k=="__proxy_id" then return rawget(p,k) end
        return make_method_proxy(name_of(k), p)
    end
    m.__tostring = function() return parent_name..":"..method_name end
    return p
end

make_instance_proxy = function(name_hint, is_global, parent_proxy)
    local p = {}; local m = {}
    PROXY_SEN[p] = true
    setmetatable(p, m)
    local hint = name_of(name_hint)
    STATE.property_store[p] = {}
    if is_global then
        STATE.registry[p] = hint
        STATE.names_used[hint] = true
    elseif parent_proxy then
        STATE.parent_map[p] = parent_proxy
    end

    local methods = {}

    local function generic_child(self2, method, arg1, timeout2)
        local n2 = name_of(arg1)
        local child = make_instance_proxy(n2, false, p)
        local var = reg_proxy(child, n2)
        local pname = STATE.registry[p] or "object"
        if timeout2 then
            emit(str_format("local %s = %s:%s(%s, %s)", var, pname, method, quote(n2), serialize(timeout2)))
        else
            emit(str_format("local %s = %s:%s(%s)", var, pname, method, quote(n2)))
        end
        return child
    end

    methods.GetService = function(self2, svc)
        local sn = name_of(svc)
        local svc_var = SERVICE_VAR_NAMES[sn] or sn
        local child = make_instance_proxy(svc_var, false, p)
        local var = reg_proxy(child, svc_var)
        local pname = STATE.registry[p] or "game"
        emit(str_format("local %s = %s:GetService(%s)", var, pname, quote(sn)))
        return child
    end
    methods.WaitForChild         = function(s,a,t)  return generic_child(s,"WaitForChild",a,t) end
    methods.FindFirstChild        = function(s,a,r)
        if r then
            local n2=name_of(a); local child=make_instance_proxy(n2,false,p)
            local var=reg_proxy(child,n2); local pname=STATE.registry[p] or "object"
            emit(str_format("local %s = %s:FindFirstChild(%s, true)",var,pname,quote(n2)))
            return child
        end
        return generic_child(s,"FindFirstChild",a)
    end
    methods.FindFirstChildOfClass    = function(s,a) return generic_child(s,"FindFirstChildOfClass",a) end
    methods.FindFirstChildWhichIsA   = function(s,a) return generic_child(s,"FindFirstChildWhichIsA",a) end
    methods.FindFirstAncestor        = function(s,a) return generic_child(s,"FindFirstAncestor",a) end
    methods.FindFirstAncestorOfClass = function(s,a) return generic_child(s,"FindFirstAncestorOfClass",a) end
    methods.FindFirstAncestorWhichIsA= function(s,a) return generic_child(s,"FindFirstAncestorWhichIsA",a) end

    methods.GetChildren = function(self2)
        local pname = STATE.registry[p] or "object"
        emit(str_format("for _, child in ipairs(%s:GetChildren()) do", pname))
        STATE.indent = STATE.indent + 1
        STATE.pending_iterator = true
        return {}
    end

    methods.GetDescendants = function(self2)
        local pname = STATE.registry[p] or "object"
        emit(str_format("for _, obj in ipairs(%s:GetDescendants()) do", pname))
        STATE.indent = STATE.indent + 1
        local obj = make_instance_proxy("obj", false)
        STATE.registry[obj] = "obj"
        STATE.property_store[obj] = {Name="Object", ClassName="Part"}
        local done = false
        return function()
            if not done then done = true; return 1, obj
            else STATE.indent=STATE.indent-1; emit("end"); return nil end
        end, nil, 0
    end

    methods.Clone = function(self2)
        local pname = STATE.registry[p] or "object"
        local child = make_instance_proxy((hint or "object").."Clone", false)
        local var = reg_proxy(child, (hint or "object").."Clone")
        emit(str_format("local %s = %s:Clone()", var, pname))
        return child
    end

    methods.Destroy      = function() emit(str_format("%s:Destroy()", STATE.registry[p] or "object")) end
    methods.Remove       = function() emit(str_format("%s:Remove()",  STATE.registry[p] or "object")) end
    methods.ClearAllChildren = function() emit(str_format("%s:ClearAllChildren()", STATE.registry[p] or "object")) end

    methods.GetFullName  = function() return STATE.registry[p] or "Instance" end
    methods.GetDebugId   = function() return "DEBUG_ID" end
    methods.IsA          = function() return true end
    methods.IsDescendantOf = function() return true end
    methods.IsAncestorOf   = function() return false end
    methods.GetAttribute   = function() return nil end
    methods.GetAttributes  = function() return {} end
    methods.SetAttribute   = function(self2, attr, val2)
        emit(str_format("%s:SetAttribute(%s, %s)", STATE.registry[p] or "object", quote(attr), serialize(val2)))
    end
    methods.GetTags  = function() return {} end
    methods.HasTag   = function() return false end
    methods.AddTag   = function() end
    methods.RemoveTag = function() end

    methods.Connect = function(self2, fn)
        local sig_name = STATE.registry[p] or "signal"
        local conn = make_instance_proxy("connection", false)
        local cvar = reg_proxy(conn, "conn")
        local ev = sig_name:match("%.([^%.]+)$") or sig_name
        local params = {"..."}
        if ev:match("InputBegan") or ev:match("InputEnded") or ev:match("InputChanged") then params={"input","gameProcessed"}
        elseif ev:match("CharacterAdded") or ev:match("CharacterRemoving") then params={"character"}
        elseif ev:match("PlayerAdded") or ev:match("PlayerRemoving") then params={"player"}
        elseif ev:match("Changed") then params={"value"}
        elseif ev:match("ChildAdded") or ev:match("ChildRemoved") then params={"child"}
        elseif ev:match("Touched") then params={"hit"}
        elseif ev:match("Heartbeat") or ev:match("RenderStepped") or ev:match("Stepped") then params={"dt"}
        elseif ev:match("FocusLost") then params={"enterPressed","inputObject"}
        elseif ev:match("Died") then params={}
        elseif ev:match("MouseButton") or ev:match("Activated") then params={}
        end
        emit(str_format("local %s = %s:Connect(function(%s)", cvar, sig_name, tbl_concat(params,", ")))
        STATE.indent = STATE.indent + 1
        if _type(fn) == "function" then
            local args={}
            for _, pr in _ipairs(params) do
                args[#args+1] = make_instance_proxy(pr, false)
                STATE.registry[args[#args]] = pr
            end
            _xpcall(function() fn(_unpack(args)) end, function() end)
        end
        while STATE.pending_iterator do STATE.indent=STATE.indent-1; emit("end"); STATE.pending_iterator=false end
        STATE.indent = STATE.indent - 1
        emit("end)")
        return conn
    end
    methods.Once       = methods.Connect
    methods.Wait       = function()
        local pname = STATE.registry[p] or "signal"
        local res   = make_instance_proxy("waitResult", false)
        local var   = reg_proxy(res, "waitResult")
        emit(str_format("local %s = %s:Wait()", var, pname))
        return res
    end
    methods.Disconnect = function() emit(str_format("%s:Disconnect()", STATE.registry[p] or "conn")) end

    methods.Fire          = function(self2, ...) local ss={};for _,v in _ipairs({...}) do ss[#ss+1]=serialize(v) end; emit(str_format("%s:Fire(%s)", STATE.registry[p] or "signal", tbl_concat(ss,", "))) end
    methods.FireServer    = function(self2, ...) local ss={};for _,v in _ipairs({...}) do ss[#ss+1]=serialize(v) end; emit(str_format("%s:FireServer(%s)", STATE.registry[p] or "RemoteEvent", tbl_concat(ss,", "))); STATE.call_graph[#STATE.call_graph+1]={remote=STATE.registry[p],kind="FireServer",args=ss} end
    methods.FireClient    = function(self2, pl, ...) local ss={serialize(pl)};for _,v in _ipairs({...}) do ss[#ss+1]=serialize(v) end; emit(str_format("%s:FireClient(%s)", STATE.registry[p] or "RemoteEvent", tbl_concat(ss,", "))) end
    methods.FireAllClients = function(self2, ...) local ss={};for _,v in _ipairs({...}) do ss[#ss+1]=serialize(v) end; emit(str_format("%s:FireAllClients(%s)", STATE.registry[p] or "RemoteEvent", tbl_concat(ss,", "))) end
    methods.InvokeServer  = function(self2, ...) local ss={};for _,v in _ipairs({...}) do ss[#ss+1]=serialize(v) end; local ret=make_instance_proxy("result",false); local var=reg_proxy(ret,"result"); emit(str_format("local %s = %s:InvokeServer(%s)", var, STATE.registry[p] or "RemoteFunction", tbl_concat(ss,", "))); STATE.call_graph[#STATE.call_graph+1]={remote=STATE.registry[p],kind="InvokeServer",args=ss}; return ret end
    methods.InvokeClient  = function(self2, pl, ...) local ss={serialize(pl)};for _,v in _ipairs({...}) do ss[#ss+1]=serialize(v) end; local ret=make_instance_proxy("result",false); local var=reg_proxy(ret,"result"); emit(str_format("local %s = %s:InvokeClient(%s)", var, STATE.registry[p] or "RemoteFunction", tbl_concat(ss,", "))); return ret end

    methods.Play   = function() emit(str_format("%s:Play()", STATE.registry[p] or "sound")) end
    methods.Stop   = function() emit(str_format("%s:Stop()", STATE.registry[p] or "sound")) end
    methods.Pause  = function() emit(str_format("%s:Pause()", STATE.registry[p] or "sound")) end
    methods.Cancel = function() emit(str_format("%s:Cancel()", STATE.registry[p] or "tween")) end

    methods.MoveTo = function(self2, pos, ap)
        local pname = STATE.registry[p] or "humanoid"
        if ap then emit(str_format("%s:MoveTo(%s, %s)", pname, serialize(pos), serialize(ap)))
        else emit(str_format("%s:MoveTo(%s)", pname, serialize(pos))) end
    end
    methods.Move          = function(self2, dir, rs) emit(str_format("%s:Move(%s, %s)", STATE.registry[p] or "humanoid", serialize(dir), serialize(rs or false))) end
    methods.EquipTool     = function(self2, t) emit(str_format("%s:EquipTool(%s)", STATE.registry[p] or "humanoid", serialize(t))) end
    methods.UnequipTools  = function() emit(str_format("%s:UnequipTools()", STATE.registry[p] or "humanoid")) end
    methods.TakeDamage    = function(self2, dmg) emit(str_format("%s:TakeDamage(%s)", STATE.registry[p] or "humanoid", serialize(dmg))) end
    methods.ChangeState   = function(self2, st) emit(str_format("%s:ChangeState(%s)", STATE.registry[p] or "humanoid", serialize(st))) end
    methods.GetState      = function() return make_instance_proxy("Enum.HumanoidStateType.Running", false) end
    methods.GetAppliedDescription = function()
        local d = make_instance_proxy("humanoidDesc", false)
        local var = reg_proxy(d, "humanoidDesc")
        emit(str_format("local %s = %s:GetAppliedDescription()", var, STATE.registry[p] or "humanoid"))
        return d
    end
    methods.ApplyDescription = function(self2, desc)
        emit(str_format("%s:ApplyDescription(%s)", STATE.registry[p] or "humanoid", serialize(desc)))
    end

    methods.LoadAnimation = function(self2, anim)
        local pname = STATE.registry[p] or "animator"
        local track = make_instance_proxy("animTrack", false)
        local var   = reg_proxy(track, "animTrack")
        emit(str_format("local %s = %s:LoadAnimation(%s)", var, pname, serialize(anim)))
        return track
    end
    methods.GetPlayingAnimationTracks = function() return {} end
    methods.AdjustSpeed  = function(self2, s) emit(str_format("%s:AdjustSpeed(%s)", STATE.registry[p] or "animTrack", serialize(s))) end
    methods.AdjustWeight = function(self2, w, f)
        local pname = STATE.registry[p] or "animTrack"
        if f then emit(str_format("%s:AdjustWeight(%s, %s)", pname, serialize(w), serialize(f)))
        else      emit(str_format("%s:AdjustWeight(%s)", pname, serialize(w))) end
    end

    methods.SetPrimaryPartCFrame = function(self2, cf) emit(str_format("%s:SetPrimaryPartCFrame(%s)", STATE.registry[p] or "model", serialize(cf))) end
    methods.GetPrimaryPartCFrame = function() return CFrame and CFrame.new(0,0,0) or make_instance_proxy("CFrame.new(0,0,0)", false) end
    methods.PivotTo       = function(self2, cf) emit(str_format("%s:PivotTo(%s)", STATE.registry[p] or "model", serialize(cf))) end
    methods.GetPivot      = function() return CFrame and CFrame.new(0,0,0) or make_instance_proxy("CFrame.new(0,0,0)", false) end
    methods.GetBoundingBox = function() return CFrame and CFrame.new(0,0,0) or make_instance_proxy("CFrame",false), Vector3 and Vector3.new(1,1,1) or make_instance_proxy("Vector3",false) end
    methods.GetExtentsSize = function() return Vector3 and Vector3.new(1,1,1) or make_instance_proxy("Vector3",false) end
    methods.TranslateBy   = function(self2, d) emit(str_format("%s:TranslateBy(%s)", STATE.registry[p] or "model", serialize(d))) end

    methods.Teleport              = function(self2, pid, pl, opts, data)
        local pname = STATE.registry[p] or "TeleportService"
        local extra = (opts and (", "..serialize(opts)) or "")..(data and (", "..serialize(data)) or "")
        emit(str_format("%s:Teleport(%s, %s%s)", pname, serialize(pid), serialize(pl), extra))
    end
    methods.TeleportToPlaceInstance = function(self2, pid, inst, pl)
        emit(str_format("%s:TeleportToPlaceInstance(%s, %s, %s)", STATE.registry[p] or "TeleportService", serialize(pid), serialize(inst), serialize(pl)))
    end
    methods.GetLocalPlayerTeleportData = function()
        local d = make_instance_proxy("teleportData", false)
        local var = reg_proxy(d, "teleportData")
        emit(str_format("local %s = %s:GetLocalPlayerTeleportData()", var, STATE.registry[p] or "TeleportService"))
        return d
    end

    methods.GetAsync    = function()   return "{}" end
    methods.SetAsync    = function()   end
    methods.UpdateAsync = function()   end
    methods.IncrementAsync = function() return 0 end
    methods.RemoveAsync = function()   end
    methods.ListKeysAsync = function()
        local pages = make_instance_proxy("keyPages", false)
        reg_proxy(pages, "keyPages")
        return pages
    end
    methods.GetDataStore        = function(self2, name2, scope)
        local sn = name_of(name2)..(scope and ("/"..name_of(scope)) or "")
        local ds = make_instance_proxy(sn, false, p)
        local var = reg_proxy(ds, sn)
        emit(str_format("local %s = %s:GetDataStore(%s%s)", var, STATE.registry[p] or "DataStoreService", quote(name_of(name2)), scope and (", "..quote(name_of(scope))) or ""))
        return ds
    end
    methods.GetGlobalDataStore  = function(self2)
        local ds = make_instance_proxy("globalStore", false, p)
        local var = reg_proxy(ds, "globalStore")
        emit(str_format("local %s = %s:GetGlobalDataStore()", var, STATE.registry[p] or "DataStoreService"))
        return ds
    end
    methods.GetOrderedDataStore = function(self2, name2)
        return methods.GetDataStore(self2, name2)
    end

    methods.HttpGet     = function(self2, url)
        local u = name_of(url)
        STATE.string_refs[#STATE.string_refs+1] = {value=u, hint="HTTP URL"}
        STATE.last_http_url = u
        return u
    end
    methods.HttpPost    = function(self2, url, body, ct)
        local u = name_of(url)
        STATE.string_refs[#STATE.string_refs+1] = {value=u, hint="HTTP POST"}
        local pname = STATE.registry[p] or "HttpService"
        local ret = make_instance_proxy("httpResponse", false)
        local var = reg_proxy(ret, "httpResp")
        emit(str_format("local %s = %s:HttpPost(%s, %s, %s)", var, pname, serialize(url), serialize(body), serialize(ct)))
        STATE.property_store[ret] = {Body="{}", StatusCode=200, Success=true}
        return ret
    end
    methods.GetAsync    = function(self2, url)
        local u = name_of(url)
        STATE.string_refs[#STATE.string_refs+1] = {value=u, hint="GetAsync URL"}
        STATE.last_http_url = u
        return "{}"
    end
    methods.PostAsync   = function(self2, url, body) return "{}" end
    methods.RequestAsync = function(self2, opts)
        local url = _type(opts)=="table" and (rawget(opts,"Url") or rawget(opts,"url") or "") or ""
        if url~="" then STATE.string_refs[#STATE.string_refs+1]={value=url,hint="RequestAsync"} end
        return {Body="{}", StatusCode=200, Success=true, Headers={}}
    end
    methods.JSONEncode  = function(self2, val2) return "{}" end
    methods.JSONDecode  = function(self2, s)    return {} end
    methods.GenerateGUID = function() return "00000000-0000-0000-0000-000000000000" end
    methods.UrlEncode   = function(self2, s) return name_of(s) end

    methods.BindToRenderStep = function(self2, name2, pri, fn)
        local pname = STATE.registry[p] or "RunService"
        emit(str_format("%s:BindToRenderStep(%s, %s, function(dt)", pname, quote(name2), serialize(pri)))
        STATE.indent = STATE.indent + 1
        if _type(fn)=="function" then _xpcall(function() fn(0.016) end, function() end) end
        STATE.indent = STATE.indent - 1
        emit("end)")
    end
    methods.UnbindFromRenderStep = function(self2, name2) emit(str_format("%s:UnbindFromRenderStep(%s)", STATE.registry[p] or "RunService", quote(name2))) end
    methods.IsServer = function() return false end
    methods.IsClient = function() return true end
    methods.IsStudio = function() return false end
    methods.IsEdit   = function() return false end

    methods.GetMouseLocation = function()
        return Vector2 and Vector2.new(960,540) or make_instance_proxy("Vector2.new(960,540)",false)
    end
    methods.GetMouseDelta = function()
        return Vector2 and Vector2.new(0,0) or make_instance_proxy("Vector2.new(0,0)",false)
    end
    methods.IsKeyDown = function() return false end
    methods.IsMouseButtonPressed = function() return false end
    methods.GetKeysPressed = function() return {} end
    methods.GetConnections = function() return {} end

    methods.SetCore    = function(self2, k, val2) emit(str_format("%s:SetCore(%s, %s)", STATE.registry[p] or "StarterGui", quote(k), serialize(val2))) end
    methods.GetCore    = function() return nil end
    methods.SetCoreGuiEnabled = function(self2, t, en) emit(str_format("%s:SetCoreGuiEnabled(%s, %s)", STATE.registry[p] or "StarterGui", serialize(t), serialize(en))) end

    methods.AddItem    = function(self2, inst, life) emit(str_format("%s:AddItem(%s, %s)", STATE.registry[p] or "Debris", serialize(inst), serialize(life or 10))) end
    methods.PlayLocalSound = function(self2, snd) emit(str_format("%s:PlayLocalSound(%s)", STATE.registry[p] or "SoundService", serialize(snd))) end

    methods.CreatePath = function(self2, params)
        local path = make_instance_proxy("path", false, p)
        local var  = reg_proxy(path, "path")
        emit(str_format("local %s = %s:CreatePath(%s)", var, STATE.registry[p] or "PathfindingService", serialize(params or {})))
        return path
    end
    methods.ComputeAsync = function(self2, origin, goal)
        emit(str_format("%s:ComputeAsync(%s, %s)", STATE.registry[p] or "path", serialize(origin), serialize(goal)))
    end
    methods.GetWaypoints = function() return {} end

    methods.WorldToScreenPoint = function(self2, pos)
        return Vector3 and Vector3.new(0,0,0) or make_instance_proxy("Vector3",false), true
    end
    methods.ScreenPointToRay = function(self2, x, y)
        return make_instance_proxy("Ray",false)
    end
    methods.GetPartsObscuringTarget = function() return {} end

    methods.Raycast  = function(self2, origin, dir, params)
        local res = make_instance_proxy("rayResult", false)
        STATE.property_store[res] = {Instance=make_instance_proxy("hitPart",false), Distance=0, Position=make_instance_proxy("hitPos",false), Normal=make_instance_proxy("hitNormal",false)}
        return res
    end
    methods.FindPartOnRay = function(self2, ray, ignore)
        return make_instance_proxy("hitPart", false), make_instance_proxy("hitPos", false), make_instance_proxy("hitNormal", false)
    end

    methods.Create  = function(self2, inst, info, props)
        local pname = STATE.registry[p] or "TweenService"
        local tween = make_instance_proxy("tween", false)
        local var   = reg_proxy(tween, "tween")
        emit(str_format("local %s = %s:Create(%s, %s, %s)", var, pname, serialize(inst), serialize(info), serialize(props or {})))
        return tween
    end

    methods.GetProductInfo = function(self2, id) return {Name="Product", PriceInRobux=0, AssetId=id} end
    methods.UserOwnsGamePassAsync = function() return false end
    methods.PlayerOwnsAsset = function() return false end
    methods.PromptPurchase     = function(self2, pl, id) emit(str_format("%s:PromptPurchase(%s, %s)", STATE.registry[p] or "MarketplaceService", serialize(pl), serialize(id))) end
    methods.PromptGamePassPurchase = function(self2, pl, id) emit(str_format("%s:PromptGamePassPurchase(%s, %s)", STATE.registry[p] or "MarketplaceService", serialize(pl), serialize(id))) end

    methods.GetTagged  = function(self2, tag) return {} end
    methods.GetObjects = function(self2, url)
        STATE.string_refs[#STATE.string_refs+1]={value=name_of(url),hint="GetObjects"}
        return {}
    end

    methods.SetNetworkOwner = function(self2, pl) emit(str_format("%s:SetNetworkOwner(%s)", STATE.registry[p] or "part", serialize(pl))) end
    methods.ApplyImpulse    = function(self2, f)  emit(str_format("%s:ApplyImpulse(%s)", STATE.registry[p] or "part", serialize(f))) end
    methods.GetNetworkOwner = function() return nil end
    methods.GetTouchingParts = function() return {} end
    methods.GetConnectedParts = function() return {} end

    methods.GetPropertyChangedSignal = function(self2, prop)
        local pname = STATE.registry[p] or "object"
        local sig = make_instance_proxy(pname..".GetPropertyChangedSignal", false)
        STATE.registry[sig] = pname..":GetPropertyChangedSignal("..quote(prop)..")"
        return sig
    end

    methods.GetPlayerFromCharacter = function(self2, char)
        local pname = STATE.registry[p] or "Players"
        local pl    = make_instance_proxy("player", false)
        local var   = reg_proxy(pl, "player")
        emit(str_format("local %s = %s:GetPlayerFromCharacter(%s)", var, pname, serialize(char)))
        return pl
    end
    methods.GetPlayerByUserId = function(self2, uid)
        local pname = STATE.registry[p] or "Players"
        local pl    = make_instance_proxy("player", false)
        local var   = reg_proxy(pl, "player")
        emit(str_format("local %s = %s:GetPlayerByUserId(%s)", var, pname, serialize(uid)))
        return pl
    end
    methods.GetMouse = function(self2)
        local pname = STATE.registry[p] or "player"
        local mouse = make_instance_proxy("mouse", false)
        local var   = reg_proxy(mouse, "mouse")
        emit(str_format("local %s = %s:GetMouse()", var, pname))
        return mouse
    end
    methods.Kick = function(self2, msg)
        local pname = STATE.registry[p] or "player"
        if msg then emit(str_format("%s:Kick(%s)", pname, serialize(msg)))
        else         emit(str_format("%s:Kick()", pname)) end
    end
    methods.GetPlayers         = function() return {} end
    methods.GetCharacterAppearance = function() return {} end

    methods.GetRankInGroup  = function() return 0 end
    methods.GetRoleInGroup  = function() return "Guest" end
    methods.IsInGroup       = function() return false end
    methods.IsFriendsWith   = function() return false end
    methods.GetFriends      = function() return make_instance_proxy("friendPages", false) end
    methods.GetNetworkPing  = function() return 50 end

    m.__index = function(self2, k)
        if k == PROXY_SEN or k == "__proxy_id" then return rawget(p, k) end

        if k=="PlaceId" or k=="GameId" or k=="placeId" or k=="gameId" then return GAME_ID end

        local pname = STATE.registry[p] or hint or "object"
        local kn    = name_of(k)

        if STATE.property_store[p] and STATE.property_store[p][k] ~= nil then
            return STATE.property_store[p][k]
        end

        if methods[kn] then
            local wrap = {}; local wm = {}
            PROXY_SEN[wrap] = true; setmetatable(wrap, wm)
            STATE.registry[wrap] = pname .. "." .. kn
            wm.__call = function(_, ...)
                local args = {...}
                if args[1] == p or (is_proxy(args[1]) and args[1] ~= wrap) then
                    tbl_remove(args, 1)
                end
                return methods[kn](p, _unpack(args))
            end
            wm.__index = function(_, k2)
                if k2==PROXY_SEN or k2=="__proxy_id" then return rawget(wrap,k2) end
                return make_instance_proxy(k2, false, wrap)
            end
            wm.__tostring = function() return pname..":"..kn end
            return wrap
        end

        if pname=="fenv" or pname=="getgenv" or pname=="_G" then
            if k=="game" then return _G.game end
            if k=="workspace" then return _G.workspace end
            if k=="script" then return _G.script end
            if k=="Enum" then return _G.Enum end
            local gv = rawget(_G, k)
            if gv ~= nil then return gv end
            return nil
        end

        if k=="Parent"    then return STATE.parent_map[p] or make_instance_proxy("Parent", false) end
        if k=="Name"      then return hint or "Object" end
        if k=="ClassName" then return hint or "Instance" end

        if k=="LocalPlayer" then
            local lp  = make_instance_proxy("LocalPlayer", false, p)
            local var = reg_proxy(lp, "LocalPlayer")
            emit(str_format("local %s = %s.LocalPlayer", var, pname))
            return lp
        end
        if k=="PlayerGui"      then return make_instance_proxy("PlayerGui", false, p) end
        if k=="Backpack"       then return make_instance_proxy("Backpack", false, p) end
        if k=="PlayerScripts"  then return make_instance_proxy("PlayerScripts", false, p) end
        if k=="UserId"         then return 1 end
        if k=="DisplayName"    then return "Player" end
        if k=="AccountAge"     then return 365 end
        if k=="MembershipType" then return make_instance_proxy("Enum.MembershipType.None", false) end
        if k=="Team"           then return make_instance_proxy("Team", false, p) end
        if k=="TeamColor"      then return BrickColor and BrickColor.new("White") or make_instance_proxy("BrickColor",false) end
        if k=="Character"      then return make_instance_proxy("Character", false, p) end
        if k=="Humanoid"       then
            local h = make_instance_proxy("Humanoid", false, p)
            STATE.property_store[h] = {Health=100, MaxHealth=100, WalkSpeed=16, JumpPower=50, JumpHeight=7.2, HipHeight=2}
            return h
        end
        if k=="HumanoidRootPart" or k=="PrimaryPart" or k=="RootPart" then
            local hrp = make_instance_proxy("HumanoidRootPart", false, p)
            STATE.property_store[hrp] = {
                Position = Vector3 and Vector3.new(0,5,0) or make_instance_proxy("Vector3",false),
                CFrame   = CFrame  and CFrame.new(0,5,0)  or make_instance_proxy("CFrame", false),
            }
            return hrp
        end
        if BODY_PARTS[k]     then return make_instance_proxy(k, false, p) end
        if k=="Animator"     then return make_instance_proxy("Animator", false, p) end
        if k=="RootJoint"    then return make_instance_proxy("RootJoint", false, p) end
        if k=="CurrentCamera" or k=="Camera" then
            local cam = make_instance_proxy("Camera", false, p)
            STATE.property_store[cam] = {FieldOfView=70, CameraType=make_instance_proxy("Enum.CameraType.Custom",false)}
            return cam
        end
        if k=="CameraType"    then return make_instance_proxy("Enum.CameraType.Custom", false) end
        if k=="CameraSubject" then return make_instance_proxy("Humanoid", false, p) end

        if NUM_PROPS[k] ~= nil  then return make_num_proxy(NUM_PROPS[k]) end

        if BOOL_PROPS[k] ~= nil then return BOOL_PROPS[k] end

        if k=="AbsoluteSize" or k=="ViewportSize" then return Vector2 and Vector2.new(1920,1080) or make_instance_proxy("Vector2",false) end
        if k=="AbsolutePosition"                   then return Vector2 and Vector2.new(0,0)       or make_instance_proxy("Vector2",false) end
        if k=="Position" then
            if hint and (hint:match("Part") or hint:match("Model") or hint:match("Root")) then
                return Vector3 and Vector3.new(0,5,0) or make_instance_proxy("Vector3",false)
            end
            return UDim2 and UDim2.new(0,0,0,0) or make_instance_proxy("UDim2",false)
        end
        if k=="Size" then
            if hint and hint:match("Part") then return Vector3 and Vector3.new(4,1,2) or make_instance_proxy("Vector3",false) end
            return UDim2 and UDim2.new(1,0,1,0) or make_instance_proxy("UDim2",false)
        end
        if k=="CFrame"                                   then return CFrame  and CFrame.new(0,5,0)   or make_instance_proxy("CFrame",false) end
        if k=="Velocity" or k=="AssemblyLinearVelocity"  then return Vector3 and Vector3.new(0,0,0)  or make_instance_proxy("Vector3",false) end
        if k=="AssemblyAngularVelocity" or k=="RotVelocity" then return Vector3 and Vector3.new(0,0,0) or make_instance_proxy("Vector3",false) end
        if k=="Orientation" or k=="Rotation"             then return Vector3 and Vector3.new(0,0,0)  or make_instance_proxy("Vector3",false) end
        if k=="LookVector"                               then return Vector3 and Vector3.new(0,0,-1) or make_instance_proxy("Vector3",false) end
        if k=="RightVector"                              then return Vector3 and Vector3.new(1,0,0)  or make_instance_proxy("Vector3",false) end
        if k=="UpVector"                                 then return Vector3 and Vector3.new(0,1,0)  or make_instance_proxy("Vector3",false) end
        if k=="Color" or k=="BackgroundColor3" or k=="TextColor3" or
           k=="BorderColor3" or k=="PlaceholderColor3" or k=="ImageColor3" or
           k=="TopSurface" or k=="BottomSurface" then
            return Color3 and Color3.new(1,1,1) or make_instance_proxy("Color3",false)
        end
        if k=="BrickColor" then return BrickColor and BrickColor.new("Medium stone grey") or make_instance_proxy("BrickColor",false) end
        if k=="Material"   then return make_instance_proxy("Enum.Material.Plastic", false) end
        if k=="Hit"        then return CFrame and CFrame.new(0,0,-10) or make_instance_proxy("CFrame",false) end
        if k=="Origin"     then return CFrame and CFrame.new(0,5,0)   or make_instance_proxy("CFrame",false) end
        if k=="Target"     then return make_instance_proxy("Target", false, p) end
        if k=="X" or k=="Y" or k=="Z" then return 0 end
        if k=="ViewSizeX" then return 1920 end
        if k=="ViewSizeY" then return 1080 end
        if k=="TextBounds" then return Vector2 and Vector2.new(0,0) or make_instance_proxy("Vector2",false) end
        if k=="Font"       then return make_instance_proxy("Enum.Font.SourceSans", false) end
        if k=="SoundId"    then return "rbxassetid://0" end
        if k=="Image" or k=="ImageContent" then return "rbxassetid://0" end
        if k=="Text" or k=="PlaceholderText" or k=="ContentText" then
            return INPUT_KEY ~= "NoKey" and INPUT_KEY or ""
        end
        if k=="Value" then
            return INPUT_KEY ~= "NoKey" and INPUT_KEY or "input"
        end

        local signal_names = {
            OnClientEvent=1, OnServerEvent=1, OnClientInvoke=1, OnServerInvoke=1,
            Heartbeat=1, RenderStepped=1, Stepped=1, Changed=1,
            ChildAdded=1, ChildRemoved=1, DescendantAdded=1, DescendantRemoving=1,
            PlayerAdded=1, PlayerRemoving=1, CharacterAdded=1, CharacterRemoving=1,
            Touched=1, TouchEnded=1, InputBegan=1, InputEnded=1, InputChanged=1,
            MouseButton1Click=1, MouseButton2Click=1, MouseButton1Down=1,
            MouseButton1Up=1, Activated=1, Deactivated=1, AncestryChanged=1,
            AttributeChanged=1,
        }
        if signal_names[k] then
            local sig = make_instance_proxy(pname.."."..kn, false)
            STATE.registry[sig] = pname.."."..kn
            return sig
        end

        return make_instance_proxy(kn, false, p)
    end

    m.__newindex = function(self2, k, v)
        local pname = STATE.registry[p] or hint or "object"
        local kn    = name_of(k)
        STATE.property_store[p]    = STATE.property_store[p] or {}
        STATE.property_store[p][k] = v
        if k == "Parent" and is_proxy(v) then STATE.parent_map[p] = v end
        emit(str_format("%s.%s = %s", pname, kn, serialize(v)))
    end

    m.__call = function(self2, ...)
        local pname = STATE.registry[p] or hint or "func"
        if pname=="fenv" or pname=="getgenv" or pname:match("env") then return p end
        local args = {...}; local ss = {}
        for _, v in _ipairs(args) do ss[#ss+1] = serialize(v) end
        local ret = make_instance_proxy("result", false)
        local var = reg_proxy(ret, "result")
        emit(str_format("local %s = %s(%s)", var, pname, tbl_concat(ss,", ")))
        return ret
    end

    local arith = make_arith_proxy
    m.__add    = arith("+");  m.__sub  = arith("-");  m.__mul  = arith("*")
    m.__div    = arith("/");  m.__mod  = arith("%");  m.__pow  = arith("^")
    m.__concat = arith("..")
    m.__eq  = function() return false end
    m.__lt  = function() return false end
    m.__le  = function() return false end
    m.__unm = function(a)
        local q={}; local qm={}; PROXY_SEN[q]=true; setmetatable(q,qm)
        local ex="(-"..(STATE.registry[a] or serialize(a))..")"
        STATE.registry[q]=ex; qm.__tostring=function() return ex end; return q
    end
    m.__len    = function() return 0 end
    m.__tostring = function() return STATE.registry[p] or hint or "Object" end
    m.__pairs  = function() return function() return nil end, p, nil end
    m.__ipairs = m.__pairs

    return p
end

_G._DUMPER_make_proxy = make_instance_proxy

local function make_roblox_type(type_name, constructors)
    local tbl = {}; local meta = {}
    meta.__index = function(self2, k)
        if k == "new" or (constructors and constructors[k]) then
            return function(...)
                local args = {...}; local ss = {}
                for _, v in _ipairs(args) do ss[#ss+1] = serialize(v) end
                local expr = type_name.."."..k.."("..tbl_concat(ss,", ")..")"
                local proxy = {}; local pm = {}
                PROXY_SEN[proxy] = true; setmetatable(proxy, pm)
                STATE.registry[proxy] = expr
                pm.__tostring = function() return expr end
                pm.__index = function(_, pk)
                    if pk==PROXY_SEN or pk=="__proxy_id" then return rawget(proxy,pk) end
                    local simple={X=0,Y=0,Z=0,W=0,Magnitude=0,R=1,G=1,B=1,Scale=0,Offset=0,Min=0,Max=0,H=1,S=1,V=1}
                    if simple[pk]~=nil then return simple[pk] end
                    if pk=="Unit" or pk=="Position" or pk=="CFrame" or pk=="Rotation" or
                       pk=="LookVector" or pk=="RightVector" or pk=="UpVector" or pk=="p" then return proxy end
                    if pk=="Width" or pk=="Height" then return UDim and UDim.new(0,0) or proxy end
                    return 0
                end
                local function binop(bop)
                    return function(a, b)
                        local p2={}; local p2m={}; PROXY_SEN[p2]=true; setmetatable(p2,p2m)
                        local as=_type(a)=="table" and (STATE.registry[a] or serialize(a)) or serialize(a)
                        local bs=_type(b)=="table" and (STATE.registry[b] or serialize(b)) or serialize(b)
                        local ex2="("..as.." "..bop.." "..bs..")"
                        STATE.registry[p2]=ex2; p2m.__tostring=function() return ex2 end
                        p2m.__index=pm.__index
                        p2m.__add=binop("+"); p2m.__sub=binop("-")
                        p2m.__mul=binop("*"); p2m.__div=binop("/")
                        return p2
                    end
                end
                pm.__add=binop("+"); pm.__sub=binop("-")
                pm.__mul=binop("*"); pm.__div=binop("/")
                pm.__unm=function(a)
                    local p2={}; local p2m={}; PROXY_SEN[p2]=true; setmetatable(p2,p2m)
                    local ex2="(-"..(STATE.registry[a] or serialize(a))..")"
                    STATE.registry[p2]=ex2; p2m.__tostring=function() return ex2 end; return p2
                end
                pm.__eq=function() return false end
                pm.__concat=function(a,b)
                    local as=_type(a)=="table" and (STATE.registry[a] or _tostring(a)) or _tostring(a)
                    local bs=_type(b)=="table" and (STATE.registry[b] or _tostring(b)) or _tostring(b)
                    return as..bs
                end
                return proxy
            end
        end
        return nil
    end
    meta.__call = function(self2, ...) return self2.new(...) end
    return setmetatable(tbl, meta)
end

Vector3    = make_roblox_type("Vector3",  {new=1,zero=1,one=1,xAxis=1,yAxis=1,zAxis=1,fromNormalId=1,fromAxis=1})
Vector2    = make_roblox_type("Vector2",  {new=1,zero=1,one=1})
UDim       = make_roblox_type("UDim",     {new=1})
UDim2      = make_roblox_type("UDim2",    {new=1,fromScale=1,fromOffset=1})
CFrame     = make_roblox_type("CFrame",   {new=1,Angles=1,lookAt=1,fromEulerAnglesXYZ=1,fromEulerAnglesYXZ=1,fromAxisAngle=1,fromMatrix=1,fromOrientation=1,identity=1,lookAlong=1})
Color3     = make_roblox_type("Color3",   {new=1,fromRGB=1,fromHSV=1,fromHex=1})
BrickColor = make_roblox_type("BrickColor",{new=1,random=1,White=1,Black=1,Red=1,Blue=1,Green=1,Yellow=1,palette=1})
TweenInfo  = make_roblox_type("TweenInfo",{new=1})
Rect       = make_roblox_type("Rect",     {new=1})
Region3    = make_roblox_type("Region3",  {new=1})
Region3int16 = make_roblox_type("Region3int16",{new=1})
Ray        = make_roblox_type("Ray",      {new=1})
NumberRange = make_roblox_type("NumberRange",{new=1})
NumberSequence = make_roblox_type("NumberSequence",{new=1})
NumberSequenceKeypoint = make_roblox_type("NumberSequenceKeypoint",{new=1})
ColorSequence = make_roblox_type("ColorSequence",{new=1})
ColorSequenceKeypoint = make_roblox_type("ColorSequenceKeypoint",{new=1})
PhysicalProperties = make_roblox_type("PhysicalProperties",{new=1})
Font       = make_roblox_type("Font",     {new=1,fromEnum=1,fromName=1,fromId=1})
RaycastParams = make_roblox_type("RaycastParams",{new=1})
OverlapParams = make_roblox_type("OverlapParams",{new=1})
PathWaypoint = make_roblox_type("PathWaypoint",{new=1})
Axes       = make_roblox_type("Axes",     {new=1})
Faces      = make_roblox_type("Faces",    {new=1})
Vector3int16 = make_roblox_type("Vector3int16",{new=1})
Vector2int16 = make_roblox_type("Vector2int16",{new=1})
CatalogSearchParams = make_roblox_type("CatalogSearchParams",{new=1})
DateTime   = make_roblox_type("DateTime", {now=1,fromUnixTimestamp=1,fromUnixTimestampMillis=1,fromIsoDate=1,fromLocalTime=1})
SharedTable = make_roblox_type("SharedTable",{new=1})

Random = {new = function(seed)
    local obj = {}
    function obj:NextNumber(lo, hi) return (lo or 0) + 0.5*((hi or 1)-(lo or 0)) end
    function obj:NextInteger(lo, hi) return math_floor((lo or 1) + 0.5*((hi or 100)-(lo or 1))) end
    function obj:NextUnitVector() return Vector3.new(0.577,0.577,0.577) end
    function obj:Shuffle(t) return t end
    function obj:Clone() return Random.new() end
    return obj
end}
setmetatable(Random, {__call=function(_, seed) return Random.new(seed) end})

Enum = make_instance_proxy("Enum", true)
local _enum_meta = _debug.getmetatable(Enum)
if _enum_meta then
    _enum_meta.__index = function(self2, k)
        if k==PROXY_SEN or k=="__proxy_id" then return rawget(self2, k) end
        local child = make_instance_proxy("Enum."..name_of(k), false)
        STATE.registry[child] = "Enum."..name_of(k)
        return child
    end
end

Instance = {new = function(class_name, parent)
    local cn  = name_of(class_name)
    local obj = make_instance_proxy(cn, false)
    local var = reg_proxy(obj, cn)
    if parent then
        local pname = STATE.registry[parent] or serialize(parent)
        emit(str_format("local %s = Instance.new(%s, %s)", var, quote(cn), pname))
        STATE.parent_map[obj] = parent
    else
        emit(str_format("local %s = Instance.new(%s)", var, quote(cn)))
    end
    return obj
end}

game      = make_instance_proxy("game", true)
workspace = make_instance_proxy("workspace", true)
script    = make_instance_proxy("script", true)
STATE.property_store[script] = {Name="DumpedScript", ClassName="LocalScript"}
STATE.property_store[game]   = {PlaceId=GAME_ID, GameId=GAME_ID, placeId=GAME_ID, gameId=GAME_ID}

local function run_fn_safely(fn, args)
    if _type(fn) ~= "function" then return end
    _xpcall(function() fn(_unpack(args or {})) end, function() end)
    while STATE.pending_iterator do
        STATE.indent = STATE.indent - 1
        emit("end")
        STATE.pending_iterator = false
    end
end

task = {
    wait = function(t)
        if t then emit(str_format("task.wait(%s)", serialize(t)))
        else       emit("task.wait()") end
        return t or 0.03, _os.clock()
    end,
    spawn = function(fn, ...)
        local args = {...}
        emit("task.spawn(function()")
        STATE.indent = STATE.indent + 1
        run_fn_safely(fn, args)
        STATE.indent = STATE.indent - 1
        emit("end)")
    end,
    delay = function(t, fn, ...)
        local args = {...}
        emit(str_format("task.delay(%s, function()", serialize(t or 0)))
        STATE.indent = STATE.indent + 1
        run_fn_safely(fn, args)
        STATE.indent = STATE.indent - 1
        emit("end)")
    end,
    defer = function(fn, ...)
        local args = {...}
        emit("task.defer(function()")
        STATE.indent = STATE.indent + 1
        run_fn_safely(fn, args)
        STATE.indent = STATE.indent - 1
        emit("end)")
    end,
    cancel    = function() emit("task.cancel(thread)") end,
    synchronize   = function() emit("task.synchronize()") end,
    desynchronize = function() emit("task.desynchronize()") end,
}

wait = function(t)
    if t then emit(str_format("wait(%s)", serialize(t)))
    else       emit("wait()") end
    return t or 0.03, _os.clock()
end
delay = function(t, fn)
    emit(str_format("delay(%s, function()", serialize(t or 0)))
    STATE.indent = STATE.indent + 1
    if _type(fn)=="function" then _xpcall(fn, function() end) end
    STATE.indent = STATE.indent - 1
    emit("end)")
end
spawn = function(fn)
    emit("spawn(function()")
    STATE.indent = STATE.indent + 1
    if _type(fn)=="function" then _xpcall(fn, function() end) end
    STATE.indent = STATE.indent - 1
    emit("end)")
end
tick        = function() return _os.time() end
time        = function() return _os.clock() end
elapsedTime = function() return _os.clock() end

local function make_env_proxy(path)
    local tbl = {}; local meta = {}
    local BLOCKED = {hookfunction=1,hookmetamethod=1,newcclosure=1,replaceclosure=1,
        checkcaller=1,iscclosure=1,islclosure=1,getrawmetatable=1,setreadonly=1,
        make_writeable=1,getrenv=1,getgc=1,getinstances=1}
    meta.__index = function(self2, k)
        if BLOCKED[k] then return nil end
        local subpath = path and (path.."."..name_of(k)) or name_of(k)
        return make_env_proxy(subpath)
    end
    meta.__newindex = function(self2, k, v)
        _G[k] = v
        emit(str_format("_G.%s = %s", name_of(k), serialize(v)))
    end
    meta.__call = function(self2, ...)
        if path then
            local args = {...}; local ss = {}
            for _, v in _ipairs(args) do ss[#ss+1] = serialize(v) end
            local ret = make_instance_proxy("result", false)
            local var = reg_proxy(ret, "result")
            emit(str_format("local %s = %s(%s)", var, path, tbl_concat(ss,", ")))
            return ret
        end
        return self2
    end
    return setmetatable(tbl, meta)
end

for _, alias in _ipairs({"G","g","ENV","env","E","e","L","l","F","f"}) do
    _G[alias] = make_env_proxy(alias)
end

local bit_impl = {}
do
    local function band(a, b) local r,f=0,1; for _=1,32 do if a%2==1 and b%2==1 then r=r+f end; a=math_floor(a/2); b=math_floor(b/2); f=f*2 end; return r end
    local function bor(a, b)  local r,f=0,1; for _=1,32 do if a%2==1 or b%2==1 then r=r+f end; a=math_floor(a/2); b=math_floor(b/2); f=f*2 end; return r end
    local function bxor(a,b)  local r,f=0,1; for _=1,32 do if a%2~=b%2 then r=r+f end; a=math_floor(a/2); b=math_floor(b/2); f=f*2 end; return r end
    local function lshift(a,b) return math_floor(a*(2^b))%4294967296 end
    local function rshift(a,b) return math_floor(a/(2^b)) end
    local function tobit(n) n=(n or 0)%4294967296; if n>=2147483648 then n=n-4294967296 end; return math_floor(n) end
    bit_impl.band=band; bit_impl.bor=bor; bit_impl.bxor=bxor
    bit_impl.lshift=lshift; bit_impl.rshift=rshift; bit_impl.tobit=tobit
    bit_impl.tohex=function(n,w) return str_format("%0"..(w or 8).."x",(n or 0)%0x100000000) end
    bit_impl.arshift=rshift; bit_impl.rol=function(n) return n end
    bit_impl.ror=function(n) return n end; bit_impl.bswap=function(n) return n end
    bit_impl.bnot=function(n) return bxor(n,0xFFFFFFFF) end
    bit_impl.btest=function(a,b) return band(a,b)~=0 end
    bit_impl.extract=function(n,f,w) w=w or 1; return band(rshift(n,f),(2^w)-1) end
    bit_impl.replace=function(n,v,f,w)
        w=w or 1; local mask=lshift((2^w)-1,f)
        return bor(band(n,bxor(0xFFFFFFFF,mask)),band(lshift(v,f),mask))
    end
    bit_impl.lrotate=bit_impl.rol; bit_impl.rrotate=bit_impl.ror
    bit_impl.countlz=function(n)
        n=tobit(n); if n==0 then return 32 end; local c=0
        if band(n,0xFFFF0000)==0 then c=c+16; n=lshift(n,16) end
        if band(n,0xFF000000)==0 then c=c+8;  n=lshift(n,8) end
        if band(n,0xF0000000)==0 then c=c+4;  n=lshift(n,4) end
        if band(n,0xC0000000)==0 then c=c+2;  n=lshift(n,2) end
        if band(n,0x80000000)==0 then c=c+1 end; return c
    end
    bit_impl.countrz=function(n)
        n=tobit(n); if n==0 then return 32 end; local c=0
        while band(n,1)==0 do n=rshift(n,1); c=c+1 end; return c
    end
end
bit=bit_impl; bit32=bit_impl

table.getn    = table.getn    or function(t) return #t end
table.foreach = table.foreach or function(t, f) for k,v in _pairs(t) do f(k,v) end end
table.foreachi= table.foreachi or function(t,f) for i,v in _ipairs(t) do f(i,v) end end
table.move    = table.move    or function(src,f,e,dst,tgt) tgt=tgt or src; for i2=f,e do tgt[dst+i2-f]=src[i2] end; return tgt end

string.split  = string.split or function(s, sep)
    local pat = "([^" .. (sep or "%s") .. "]+)"
    local r = {}
    for part in s:gmatch(pat) do r[#r+1] = part end
    return r
end

if not math.frexp then
    math.frexp=function(x) if x==0 then return 0,0 end; local e=math_floor(math.log(math.abs(x))/math.log(2))+1; return x/2^e,e end
end
if not math.ldexp then math.ldexp=function(m,e) return m*2^e end end

if not utf8 then
    utf8={}
    utf8.char=function(...) local a={...};local r={};for _,c in _ipairs(a) do r[#r+1]=string.char(c%256) end; return tbl_concat(r) end
    utf8.len=function(s) return #s end
    utf8.codes=function(s) local i=0; return function() i=i+1; if i<=#s then return i,s:byte(i) end end end
end

pairs  = function(t) if _type(t)=="table" and not is_proxy(t) then return _pairs(t) end; return function() return nil end, t, nil end
ipairs = function(t) if _type(t)=="table" and not is_proxy(t) then return _ipairs(t) end; return function() return nil end, t, 0 end

_G.pairs=pairs; _G.ipairs=ipairs; _G.math=math; _G.table=table; _G.string=string
_G.os=_os; _G.coroutine=coroutine; _G.io=nil; _G.utf8=utf8
_G.next=next; _G.tostring=tostring; _G.tonumber=tonumber
_G.getmetatable=getmetatable; _G.setmetatable=setmetatable
_G.pcall=function(fn,...)
    local results={_pcall(fn,...)}
    if not results[1] then local err=results[2]; if _type(err)=="string" and err:match("TIMEOUT") then _error(err) end end
    return _unpack(results)
end
_G.xpcall=function(fn,handler,...)
    local function wh(e) if _type(e)=="string" and e:match("TIMEOUT") then return e end; return handler and handler(e) or e end
    local results={_xpcall(fn,wh,...)}
    if not results[1] then local err=results[2]; if _type(err)=="string" and err:match("TIMEOUT") then _error(err) end end
    return _unpack(results)
end
_G.error=error; _G.assert=assert; _G.select=_select; _G.type=type
_G.rawget=rawget; _G.rawset=rawset; _G.rawequal=rawequal
_G.rawlen=rawlen or function(t) return #t end
_G.unpack=table.unpack or unpack
_G.pack=table.pack or function(...) return {n=_select("#",...), ...} end
_G.task=task; _G.wait=wait; _G.Wait=wait; _G.delay=delay; _G.Delay=delay
_G.spawn=spawn; _G.Spawn=spawn; _G.tick=tick; _G.time=time; _G.elapsedTime=elapsedTime
_G.game=game; _G.Game=game; _G.workspace=workspace; _G.Workspace=workspace
_G.script=script; _G.Enum=Enum; _G.Instance=Instance; _G.Random=Random
_G.Vector3=Vector3; _G.Vector2=Vector2; _G.CFrame=CFrame; _G.Color3=Color3
_G.BrickColor=BrickColor; _G.UDim=UDim; _G.UDim2=UDim2; _G.TweenInfo=TweenInfo
_G.Rect=Rect; _G.Region3=Region3; _G.Region3int16=Region3int16; _G.Ray=Ray
_G.NumberRange=NumberRange; _G.NumberSequence=NumberSequence
_G.NumberSequenceKeypoint=NumberSequenceKeypoint; _G.ColorSequence=ColorSequence
_G.ColorSequenceKeypoint=ColorSequenceKeypoint; _G.PhysicalProperties=PhysicalProperties
_G.Font=Font; _G.RaycastParams=RaycastParams; _G.OverlapParams=OverlapParams
_G.PathWaypoint=PathWaypoint; _G.Axes=Axes; _G.Faces=Faces
_G.Vector3int16=Vector3int16; _G.Vector2int16=Vector2int16
_G.CatalogSearchParams=CatalogSearchParams; _G.DateTime=DateTime
_G.SharedTable=SharedTable; _G.bit=bit; _G.bit32=bit32

getmetatable = function(x)
    if is_proxy(x) then return "The metatable is locked" end
    return _getmeta(x)
end
_G.getmetatable=getmetatable

type = function(x)
    if is_num_proxy(x) then return "number" end
    if is_proxy(x)     then return "userdata" end
    return _type(x)
end
_G.type=type

typeof = function(x)
    if is_num_proxy(x) then return "number" end
    if is_proxy(x) then
        local reg = STATE.registry[x]
        if reg then
            if reg:match("Vector3") then return "Vector3" end
            if reg:match("CFrame")  then return "CFrame" end
            if reg:match("Color3")  then return "Color3" end
            if reg:match("UDim2")   then return "UDim2" end
            if reg:match("UDim")    then return "UDim" end
            if reg:match("Enum")    then return "EnumItem" end
            if reg:match("Vector2") then return "Vector2" end
        end
        return "Instance"
    end
    return _type(x)
end
_G.typeof=typeof

tonumber = function(x, base)
    if is_num_proxy(x) then return GAME_ID end
    return _tonumber(x, base)
end
_G.tonumber=tonumber

tostring = function(x)
    if is_proxy(x) then return STATE.registry[x] or "Instance" end
    return _tostring(x)
end
_G.tostring=tostring

rawequal = function(a, b) return _rawequal(a, b) end
_G.rawequal=rawequal

local KNOWN_LIBS = {
    {p="rayfield",  n="Rayfield"},  {p="orion",    n="OrionLib"},
    {p="kavo",      n="Kavo"},      {p="venyx",    n="Venyx"},
    {p="sirius",    n="Sirius"},    {p="linoria",  n="Linoria"},
    {p="wally",     n="Wally"},     {p="dex",      n="Dex"},
    {p="infinite",  n="InfiniteYield"}, {p="hydroxide",n="Hydroxide"},
    {p="simplespy", n="SimpleSpy"}, {p="remotespy",n="RemoteSpy"},
    {p="sentinel",  n="Sentinel"},  {p="fluxus",   n="Fluxus"},
    {p="synapse",   n="Synapse"},   {p="scriptware",n="Scriptware"},
}

STATE.last_http_url = nil

loadstring = function(code, chunk_name)
    if _type(code) ~= "string" then
        return function() return make_instance_proxy("loaded", false) end
    end
    local url = STATE.last_http_url or code
    STATE.last_http_url = nil
    local url_lower = url:lower()
    for _, lib in _ipairs(KNOWN_LIBS) do
        if url_lower:find(lib.p) then
            local proxy = make_instance_proxy(lib.n, false)
            STATE.registry[proxy] = lib.n
            STATE.names_used[lib.n] = true
            if url:match("^https?://") then
                emit(str_format('local %s = loadstring(game:HttpGet("%s"))()', lib.n, url))
            end
            return function() return proxy end
        end
    end
    if url:match("^https?://") then
        local proxy = make_instance_proxy("Library", false)
        emit(str_format('local library = loadstring(game:HttpGet("%s"))()', url))
        return function() return proxy end
    end

    if _type(code) == "string" then
        local san = CLI.no_sanitize and code or sanitize(code)
        local fn2, err = _load(san, chunk_name or "nested")
        if fn2 then
            return fn2
        end

        local fn3, _ = _load(code, chunk_name or "nested_raw")
        if fn3 then return fn3 end
    end
    local proxy = make_instance_proxy("LoadedChunk", false)
    return function() return proxy end
end
load     = loadstring
_G.loadstring = loadstring
_G.load       = loadstring

require = function(mod)
    local mod_name = STATE.registry[mod] or serialize(mod)
    local result   = make_instance_proxy("RequiredModule", false)
    local var      = reg_proxy(result, "module")
    emit(str_format("local %s = require(%s)", var, mod_name))
    return result
end
_G.require = require

print = function(...)
    local args={...}; local ss={}
    for _, v in _ipairs(args) do ss[#ss+1]=serialize(v) end
    emit(str_format("print(%s)", tbl_concat(ss,", ")))
end
_G.print=print

warn = function(...)
    local args={...}; local ss={}
    for _, v in _ipairs(args) do ss[#ss+1]=serialize(v) end
    emit(str_format("warn(%s)", tbl_concat(ss,", ")))
end
_G.warn=warn

shared = make_instance_proxy("shared", true)
_G.shared=shared

local exploit_funcs = {
    request=function(opts)
        local url = _type(opts)=="table" and (rawget(opts,"Url") or rawget(opts,"url") or "") or _tostring(opts)
        if url~="" then STATE.string_refs[#STATE.string_refs+1]={value=url,hint="request"}; STATE.last_http_url=url end
        return {Body="{}", StatusCode=200, Success=true, Headers={}}
    end,
    http_request=function(opts) return exploit_funcs.request(opts) end,
    syn={request=function(o) return exploit_funcs.request(o) end},
    http={request=function(o) return exploit_funcs.request(o) end},
    setclipboard=function(t) emit(str_format("setclipboard(%s)", serialize(t))) end,
    getclipboard=function() return "" end,
    identifyexecutor=function() return "Dumper","5.0" end,
    getexecutorname=function() return "Dumper" end,
    gethui=function()
        local ui=make_instance_proxy("HiddenUI",false)
        reg_proxy(ui,"HiddenUI")
        emit(str_format("local %s = gethui()", STATE.registry[ui]))
        return ui
    end,
    gethiddenui=function() return exploit_funcs.gethui() end,
    protectgui=function() end,
    iswindowactive=function() return true end, isrbxactive=function() return true end, isgameactive=function() return true end,
    getconnections=function() return {} end, firesignal=function() end,
    fireclickdetector=function() end, fireproximityprompt=function() end,
    firetouchinterest=function() end, getinstances=function() return {} end,
    getnilinstances=function() return {} end, getgc=function() return {} end,
    getscripts=function() return {} end, getrunningscripts=function() return {} end,
    getloadedmodules=function() return {} end, getcallingscript=function() return script end,
    readfile=function(path) emit(str_format("readfile(%s)", quote(path))); return "" end,
    writefile=function(path,data) emit(str_format("writefile(%s, %s)", quote(path), serialize(data))) end,
    appendfile=function(path,data) emit(str_format("appendfile(%s, %s)", quote(path), serialize(data))) end,
    loadfile=function(path) return function() return make_instance_proxy("loaded_file",false) end end,
    listfiles=function() return {} end, isfile=function() return false end, isfolder=function() return false end,
    makefolder=function(path) emit(str_format("makefolder(%s)", quote(path))) end,
    delfolder=function(path)  emit(str_format("delfolder(%s)",  quote(path))) end,
    delfile=function(path)    emit(str_format("delfile(%s)",    quote(path))) end,
    Drawing={new=function(dt)
        local obj=make_instance_proxy("Drawing_"..name_of(dt),false)
        local var=reg_proxy(obj,name_of(dt))
        emit(str_format("local %s = Drawing.new(%s)", var, quote(name_of(dt))))
        return obj
    end, Fonts=make_instance_proxy("Drawing.Fonts",false)},
    crypt={
        base64encode=function(s) return s end, base64decode=function(s) return s end,
        base64_encode=function(s) return s end, base64_decode=function(s) return s end,
        encrypt=function(s) return s end, decrypt=function(s) return s end,
        hash=function() return "hash" end,
        generatekey=function(n) return str_rep("0",n or 32) end,
        generatebytes=function(n) return str_rep("\0",n or 16) end,
    },
    base64_encode=function(s) return s end, base64_decode=function(s) return s end,
    base64encode=function(s) return s end, base64decode=function(s) return s end,
    mouse1click=function() emit("mouse1click()") end,
    mouse1press=function() emit("mouse1press()") end,
    mouse1release=function() emit("mouse1release()") end,
    mouse2click=function() emit("mouse2click()") end,
    mouse2press=function() emit("mouse2press()") end,
    mouse2release=function() emit("mouse2release()") end,
    mousemoverel=function(x,y) emit(str_format("mousemoverel(%s, %s)", serialize(x), serialize(y))) end,
    mousemoveabs=function(x,y) emit(str_format("mousemoveabs(%s, %s)", serialize(x), serialize(y))) end,
    mousescroll=function(d) emit(str_format("mousescroll(%s)", serialize(d))) end,
    keypress=function(k)   emit(str_format("keypress(%s)",  serialize(k))) end,
    keyrelease=function(k) emit(str_format("keyrelease(%s)",serialize(k))) end,
    keyclick=function(k)   emit(str_format("keyclick(%s)",  serialize(k))) end,
    isreadonly=function() return false end,
    setreadonly=function(t) return t end, make_writeable=function(t) return t end,
    make_readonly=function(t) return t end,
    getthreadidentity=function() return 7 end, setthreadidentity=function() end,
    getidentity=function() return 7 end, setidentity=function() end,
    getthreadcontext=function() return 7 end, setthreadcontext=function() end,
    getcustomasset=function(path) return "rbxasset://"..name_of(path) end,
    getsynasset=function(path) return "rbxasset://"..name_of(path) end,
    getinfo=function() return {source="=",what="Lua",name="unknown",short_src="dumper"} end,
    getconstants=function() return {} end, getupvalues=function() return {} end,
    getprotos=function() return {} end, getupvalue=function() return nil end,
    setupvalue=function() end, setconstant=function() end, getconstant=function() return nil end,
    getproto=function() return function() end end, setproto=function() end,
    getstack=function() return nil end, setstack=function() end,
    debug={
        getinfo=_getinfo or function() return {} end,
        getupvalue=debug.getupvalue or function() return nil end,
        setupvalue=debug.setupvalue or function() end,
        getmetatable=_debug.getmetatable, setmetatable=debug.setmetatable or setmetatable,
        traceback=debug.traceback or function() return "" end,
        profilebegin=function() end, profileend=function() end, sethook=function() end,
    },
    rconsoleprint=function() end, rconsoleclear=function() end, rconsolecreate=function() end,
    rconsoledestroy=function() end, rconsoleinput=function() return "" end,
    rconsoleinfo=function() end, rconsolewarn=function() end, rconsoleerr=function() end,
    rconsolename=function() end, printconsole=function() end,
    setfflag=function() end, getfflag=function() return "" end,
    setfpscap=function(n) emit(str_format("setfpscap(%s)", serialize(n))) end,
    getfpscap=function() return 60 end,
    isnetworkowner=function() return true end,
    gethiddenproperty=function() return nil end,
    sethiddenproperty=function(obj,prop,val) emit(str_format("sethiddenproperty(%s, %s, %s)", serialize(obj), quote(prop), serialize(val))) end,
    setsimulationradius=function(r,mr) emit(str_format("setsimulationradius(%s%s)", serialize(r), mr and (", "..serialize(mr)) or "")) end,
    getspecialinfo=function() return {} end,
    saveinstance=function(opts) emit(str_format("saveinstance(%s)", serialize(opts or {}))) end,
    decompile=function() return "" end,
    lz4compress=function(s) return s end, lz4decompress=function(s) return s end,
    MessageBox=function() return 1 end, setwindowactive=function() end, setwindowtitle=function() end,
    queue_on_teleport=function(code) emit(str_format("queue_on_teleport(%s)", serialize(code))) end,
    queueonteleport=function(code)   emit(str_format("queueonteleport(%s)", serialize(code))) end,
    secure_call=function(fn,...) return fn(...) end,
    create_secure_function=function(fn) return fn end,
    isvalidinstance=function(x) return x~=nil end,
    validcheck=function(x) return x~=nil end,
    clonefunction=function(fn) return fn end,
    newcclosure=function(fn) return fn end,
    hookfunction=function(f, h) return f end,
    hookmetamethod=function(x, method, hook) return function() end end,
    replaceclosure=function(f, h) return f end,
    getrawmetatable=function(x)
        if is_proxy(x) then return _debug.getmetatable(x) end
        return {}
    end,
    setrawmetatable=function(x, mt) return x end,
    getnamecallmethod=function() return "__namecall" end,
    setnamecallmethod=function(m) end,
    checkcaller=function() return true end,
    islclosure=function(f) return _type(f)=="function" end,
    iscclosure=function(f) return false end,
    getfenv=function(depth) return _G end,
    setfenv=function(fn, env)
        if _type(fn)~="function" then return fn end
        local i=1
        while true do
            local nm=_debug.getupvalue(fn,i)
            if nm=="_ENV" then _debug.setupvalue(fn,i,env); break
            elseif not nm then break end
            i=i+1
        end
        return fn
    end,
    request=function(opts)
        local url = _type(opts)=="table" and (rawget(opts,"Url") or rawget(opts,"url") or "") or _tostring(opts)
        if url~="" then STATE.string_refs[#STATE.string_refs+1]={value=url,hint="request"}; STATE.last_http_url=url end
        emit(str_format("request(%s)", serialize(opts or {})))
        return {Success=true, StatusCode=200, StatusMessage="OK", Headers={}, Body="{}"}
    end,
}

for k, v in _pairs(exploit_funcs) do _G[k] = v end
_G.hookfunction=nil; _G.hookmetamethod=nil; _G.newcclosure=nil

local _gbase = _G
local _proxy_G = setmetatable({}, {
    __index = function(_, k)
        if CFG.VERBOSE then
            local v2 = rawget(_gbase, k)
            if v2 ~= nil then
                local vt = _type(v2)
                if vt == "table" then _print("[VERBOSE] Global table: " .. _tostring(k))
                elseif vt == "function" then _print("[VERBOSE] Global func: " .. _tostring(k))
                else _print("[VERBOSE] Global value: " .. _tostring(k) .. " = " .. _tostring(v2)) end
            else
                _print("[VERBOSE] Missing global: " .. _tostring(k))
            end
        end
        return rawget(_gbase, k)
    end,
    __newindex = function(_, k, v) rawset(_gbase, k, v) end,
})
_G._G = _proxy_G

local function dump_env()
    local function scan(prefix, env)
        if _type(env) ~= "table" then return end
        for k, v in _pairs(env) do
            _pcall(function()
                local vt = _type(v)
                if vt=="function" or vt=="thread" or vt=="userdata" then return end
                local kd = serialize(k); local vd = serialize(v)
                if vd~="nil" and vd~="{}" then
                    emit(prefix.."["..kd.."] = "..vd)
                end
            end)
        end
    end
    local envs = {
        ["_G"]=_G, ["shared"]=shared,
        ["getgenv"]= (type(getgenv)=="function") and getgenv() or nil,
        ["getrenv"]= (type(getrenv)=="function") and getrenv() or nil,
        ["getreg"] = (type(getreg)=="function")  and getreg()  or nil,
    }
    for name, env in _pairs(envs) do
        if env then scan(name, env) end
    end
end

local function build_sandbox(extra)
    local sb = setmetatable(
        {
            LuraphContinue = function() end,
            script=script, game=game, workspace=workspace,
            _G=_proxy_G,
        },
        {__index=_G, __newindex=_G}
    )
    if extra then
        for k, v in _pairs(extra) do sb[k] = v end
    end
    return sb
end

local function timed_exec(fn, sandbox, timeout_sec)
    if setfenv then setfenv(fn, sandbox) end
    local t0 = _os.clock()
    _sethook(function()
        if _os.clock() - t0 > timeout_sec then
            _error("TIMEOUT_FORCED_BY_DUMPER", 0)
        end
    end, "", 500)
    local ok, err = _xpcall(fn, function(e) return _tostring(e) end)
    _sethook()
    return ok, err
end

local function try_load(source, label)
    local fn, err = _load(source, label)
    if fn then return fn, nil end

    if CFG.VERBOSE then
        _print(str_format("[%s] Load error: %s", label, err or "?"))
    end
    return nil, err
end

local function execute_source(src_text, label, extra_env, timeout_sec)
    local fn, err = try_load(src_text, label)
    if not fn then return false, err end
    local sb = build_sandbox(extra_env)
    local ok, e = timed_exec(fn, sb, timeout_sec or CFG.TIMEOUT_SECONDS)
    return ok, e
end

local function run_dump(raw_src)

    local hooked_src = nil
    local hook_env   = {}
    if CLI.hook_op then
        _print("[hookOp] Instrumenting source...")
        local ok2, result = _pcall(HOOKOP.instrument, raw_src)
        if ok2 and result and #result > 10 then
            hooked_src = result
            hook_env   = HOOKOP.make_hooks()
            _print(str_format("[hookOp] Instrumented: %d bytes", #hooked_src))
            if CLI.verbose then
                local dbg_path = (CLI.output or "dumped_output"):gsub("%.lua$","").."_hookop_debug.lua"
                local dbg_f = _io.open(dbg_path, "w")
                if dbg_f then dbg_f:write(hooked_src); dbg_f:close()
                    _print("[hookOp] Instrumented source saved: " .. dbg_path) end
            end
            local syntax_ok, syntax_err = _load(hooked_src, "hookop_check")
            if not syntax_ok then
                _print("[hookOp] Syntax error in instrumented code: " .. _tostring(syntax_err))
                local dbg_path2 = (CLI.output or "dumped_output"):gsub("%.lua$","").."_hookop_debug.lua"
                local dbg_f2 = _io.open(dbg_path2, "w")
                if dbg_f2 then dbg_f2:write(hooked_src); dbg_f2:close()
                    _print("[hookOp] Saved instrumented source for inspection: " .. dbg_path2) end
                local line_num = syntax_err and _tonumber(syntax_err:match(":(%d+):")) or nil
                if line_num then
                    local lines = {}
                    for ln in hooked_src:gmatch("[^\n]*") do lines[#lines+1]=ln end
                    local lo = math.max(1, line_num-3)
                    local hi = math.min(#lines, line_num+3)
                    _print("[hookOp] Context around error (line " .. line_num .. "):")
                    for li = lo, hi do
                        local marker = li == line_num and ">>" or "  "
                        _print(str_format("  %s %4d: %s", marker, li, lines[li] or ""))
                    end
                end
                _print("[hookOp] Falling back to standard execution")
                hooked_src = nil
            end
        else
            _print("[hookOp] Instrumentation failed: " .. _tostring(result))
            _print("[hookOp] Falling back to standard execution")
        end
    end

    local sanitized = CLI.no_sanitize and raw_src or sanitize(raw_src)

    local success = false
    local last_err = ""

    if hooked_src and not success then
        _print("[Dumper] Strategy A: hookOp instrumented execution")
        local ok, err = execute_source(hooked_src, "HookOp_Script", hook_env)
        if ok then success = true
        else
            _print("[Dumper] Strategy A failed: " .. _tostring(err))
            last_err = err
        end
    end

    if not success then
        _print("[Dumper] Strategy B: sanitized execution")
        local ok, err = execute_source(sanitized, "Sanitized_Script", nil)
        if ok then success = true
        else
            _print("[Dumper] Strategy B failed: " .. _tostring(err))
            last_err = err
        end
    end

    if not success and not CLI.no_sanitize then
        _print("[Dumper] Strategy C: raw source execution")
        local ok, err = execute_source(raw_src, "Raw_Script", nil)
        if ok then success = true
        else
            _print("[Dumper] Strategy C failed: " .. _tostring(err))
            last_err = err
        end
    end

    if not success then
        _print("[Dumper] Strategy D: VM extraction")

        local inner_srcs = {}
        for chunk in raw_src:gmatch('load[sS]tring%((["\'][^"\']+["\'])%)') do
            inner_srcs[#inner_srcs+1] = chunk
        end
        for _, cs in _ipairs(inner_srcs) do
            local fn2, _ = _load("return "..cs)
            if fn2 then
                local ok2, decoded2 = _pcall(fn2)
                if ok2 and _type(decoded2)=="string" and #decoded2 > 100 then
                    local san2 = sanitize(decoded2)
                    local ok3, err3 = execute_source(san2, "Extracted_Script", nil, CFG.TIMEOUT_SECONDS * 2)
                    if ok3 then success=true; break
                    else last_err=err3 end
                end
            end
        end
        if not success then
            _print("[Dumper] Strategy D: no extractable inner payload")
        end
    end

    if not success and last_err and _tostring(last_err):match("TIMEOUT") then
        _print("[Dumper] Strategy E: extended timeout retry")
        local ok, err = execute_source(sanitized, "Extended_Script", nil, CFG.TIMEOUT_SECONDS * 3)
        if ok then success = true else last_err = err end
    end

    if not success then
        _print(str_format("[Dumper] All strategies failed. Last error: %s", _tostring(last_err)))
        emit(str_format('print("[Dumper] Execution failed: %s")', _tostring(last_err):gsub('"','\\"')))
    end

    dump_env()
    return success
end

local Dumper = {}

function Dumper.reset()
    reset_state()
    game      = make_instance_proxy("game", true)
    workspace = make_instance_proxy("workspace", true)
    script    = make_instance_proxy("script", true)
    Enum      = make_instance_proxy("Enum", true)
    shared    = make_instance_proxy("shared", true)
    STATE.property_store[game]   = {PlaceId=GAME_ID,GameId=GAME_ID,placeId=GAME_ID,gameId=GAME_ID}
    STATE.property_store[script] = {Name="DumpedScript",ClassName="LocalScript"}
    _G.game=game; _G.Game=game; _G.workspace=workspace; _G.Workspace=workspace
    _G.script=script; _G.Enum=Enum; _G.shared=shared
    local em = _debug.getmetatable(Enum)
    if em then
        em.__index = function(self2, k)
            if k==PROXY_SEN or k=="__proxy_id" then return rawget(self2,k) end
            local child = make_instance_proxy("Enum."..name_of(k), false)
            STATE.registry[child] = "Enum."..name_of(k)
            return child
        end
    end
end

function Dumper.get_output()    return get_output() end
function Dumper.save(path)      return save_output(path) end
function Dumper.get_call_graph() return STATE.call_graph end
function Dumper.get_string_refs() return STATE.string_refs end
function Dumper.get_stats()
    return {
        total_lines       = #STATE.output,
        remote_calls      = #STATE.call_graph,
        suspicious_strings = #STATE.string_refs,
        captured_strings  = #STATE.captured_strings,
    }
end

function Dumper.dump_file(input_path, output_path)
    Dumper.reset()
    local f = _io.open(input_path, "rb")
    if not f then _print("[Dumper] Cannot open: " .. input_path); return false end
    local raw_src = f:read("*a"); f:close()
    local ok = run_dump(raw_src)
    return save_output(output_path or CFG.OUTPUT_FILE)
end

function Dumper.dump_string(code, output_path)
    Dumper.reset()
    emit_blank()
    local ok = run_dump(code)
    if output_path then return save_output(output_path) end
    return ok, get_output()
end

_G.LuraphContinue = function() end

if CLI.input then
    _print(str_format("[Dumper] Input: %s", CLI.input))
    _print(str_format("[Dumper] Output: %s", CLI.output or CFG.OUTPUT_FILE))
    _print(str_format("[Dumper] Key: %s | GameId: %s | Timeout: %ds | hookOp: %s",
        CLI.key, _tostring(CLI.game_id), CLI.timeout, _tostring(CLI.hook_op)))

    local ok = Dumper.dump_file(CLI.input, CLI.output)
    if ok then
        local out_path = CLI.output or CFG.OUTPUT_FILE
        _print("\n[Dumper] Saved to: " .. out_path)
        local stats = Dumper.get_stats()
        _print(str_format("[Dumper] Lines: %d | Remotes: %d | Strings: %d | Constants: %d",
            stats.total_lines, stats.remote_calls, stats.suspicious_strings,
            stats.captured_strings))

        if #Dumper.get_string_refs() > 0 then
            _print("\n[Dumper] Suspicious strings:")
            for _, s in _ipairs(Dumper.get_string_refs()) do
                _print(str_format("  [%s] %s", s.hint, s.value))
            end
        end
        _print("[Dumper] Renaming variables...")
        local renamed_path = out_path:gsub("%.lua$", "") .. "_renamed.lua"
        local renamer_cmd = str_format('./renamer %s %s', out_path, renamed_path)
        local rename_ok = _os.execute(renamer_cmd)
        if rename_ok then
            _print("[Dumper] Renamed output: " .. renamed_path)
        else
            local renamer_cmd2 = str_format('renamer %s %s', out_path, renamed_path)
            local rename_ok2 = _os.execute(renamer_cmd2)
            if rename_ok2 then
                _print("[Dumper] Renamed output: " .. renamed_path)
            else
                _print("[Dumper] Renamer not found — skipping rename step")
                _print("[Dumper] To rename manually: ./renamer " .. out_path .. " " .. renamed_path)
            end
        end
    else
        _print("[Dumper] Dump failed — check output file for partial results")
    end
else

    local probe = _io.open("obfuscated.lua", "rb")
    if probe then
        probe:close()
        _print("[Dumper] Found obfuscated.lua, dumping...")
        local ok = Dumper.dump_file("obfuscated.lua")
        if ok then
            _print("[Dumper] Saved to: " .. CFG.OUTPUT_FILE)
            local stats = Dumper.get_stats()
            _print(str_format("[Dumper] Lines: %d | Remotes: %d",
                stats.total_lines, stats.remote_calls))
        end
    else
        CLI.usage()
    end
end

return Dumper

