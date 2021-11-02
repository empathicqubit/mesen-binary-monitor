local _p = emu.log
local function print(data)
  _p(data .. "")
end

local socket = require("socket.core")

local running = true

local regMeta = {
  a =  { name = "A",  id = 0, size = 1 },
  x =  { name = "X",  id = 1, size = 1 },
  y =  { name = "Y",  id = 2, size = 1 },
  pc = { name = "PC", id = 3, size = 2 },
  sp =  { name = "SP", id = 4, size = 1 },
  status =  { name = "FL", id = 5, size = 1 },
}

local host = os.getenv("FCEUX_REMOTE_HOST") or "localhost"
local port = os.getenv("FCEUX_REMOTE_PORT") or 9355

print("Binding to host '" ..host.. "' and port " ..port.. "...")

local server = assert(socket.tcp())
assert(server:bind(host, port))
assert(server:listen(32))
server:settimeout(0)

local i, p   = server:getsockname()
assert(i, p)

print("Waiting for connection on " .. i .. ":" .. p .. "...")
local conn = nil

local function boolToLittleEndian(b)
    local value = 0
    if b then
        value = 1
    end
    return string.char(value & 0xff)
end

local function uint8ToLittleEndian(value)
    return string.char(value & 0xff)
end

local function uint16ToLittleEndian(value)
    return string.char(value & 0xff, (value >> 8) & 0xff)
end

local function uint32ToLittleEndian(value)
    return string.char(value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >> 24) & 0xff)
end

local function readUint32(data, index)
    return data:byte(index) + (data:byte(index + 1) << 8) + (data:byte(index + 2) << 16) + (data:byte(index + 3) << 24)
end

local function readUint16(data, index)
    return data:byte(index) + (data:byte(index + 1) << 8)
end

local function readUint8(data, index)
    return data:byte(index)
end

local function readBool(data, index)
    return data:byte(index) > 0
end

local errorType = {
    OK = 0x00,
    OBJECT_MISSING = 0x01,
    INVALID_MEMSPACE = 0x02,
    CMD_INVALID_LENGTH = 0x80,
    INVALID_PARAMETER = 0x81,
    CMD_INVALID_API_VERSION = 0x82,
    CMD_INVALID_TYPE = 0x83,
    CMD_FAILURE = 0x8f,
};

local commandType = {
    INVALID = 0x00,

    MEM_GET = 0x01,
    MEM_SET = 0x02,

    CHECKPOINT_GET = 0x11,
    CHECKPOINT_SET = 0x12,
    CHECKPOINT_DELETE = 0x13,
    CHECKPOINT_LIST = 0x14,
    CHECKPOINT_TOGGLE = 0x15,

    CONDITION_SET = 0x22,

    REGISTERS_GET = 0x31,
    REGISTERS_SET = 0x32,

    DUMP = 0x41,
    UNDUMP = 0x42,

    RESOURCE_GET = 0x51,
    RESOURCE_SET = 0x52,

    ADVANCE_INSTRUCTIONS = 0x71,
    KEYBOARD_FEED = 0x72,
    EXECUTE_UNTIL_RETURN = 0x73,

    PING = 0x81,
    BANKS_AVAILABLE = 0x82,
    REGISTERS_AVAILABLE = 0x83,
    DISPLAY_GET = 0x84,
    VICE_INFO = 0x85,

    PALETTE_GET = 0x91,

    EXIT = 0xaa,
    QUIT = 0xbb,
    RESET = 0xcc,
    AUTOSTART = 0xdd,
}

local responseType = {
    MEM_GET = 0x01,
    MEM_SET = 0x02,

    CHECKPOINT_INFO = 0x11,

    CHECKPOINT_DELETE = 0x13,
    CHECKPOINT_LIST = 0x14,
    CHECKPOINT_TOGGLE = 0x15,

    CONDITION_SET = 0x22,

    REGISTER_INFO = 0x31,

    DUMP = 0x41,
    UNDUMP = 0x42,

    RESOURCE_GET = 0x51,
    RESOURCE_SET = 0x52,

    JAM = 0x61,
    STOPPED = 0x62,
    RESUMED = 0x63,

    ADVANCE_INSTRUCTIONS = 0x71,
    KEYBOARD_FEED = 0x72,
    EXECUTE_UNTIL_RETURN = 0x73,

    PING = 0x81,
    BANKS_AVAILABLE = 0x82,
    REGISTERS_AVAILABLE = 0x83,
    DISPLAY_GET = 0x84,
    VICE_INFO = 0x85,

    PALETTE_GET = 0x91,

    EXIT = 0xaa,
    QUIT = 0xbb,
    RESET = 0xcc,
    AUTOSTART = 0xdd,
}

local API_VERSION = 0x02

local EVENT_ID = 0xffffffff

local function response(responseType, errorCode, requestId, body)
    if conn == nil then
        return
    end

    local r = {}
    r[#r+1] = string.char(0x02)
    r[#r+1] = uint8ToLittleEndian(API_VERSION)
    if body ~= nil then
        r[#r+1] = uint32ToLittleEndian(body:len())
    else
        r[#r+1] = uint32ToLittleEndian(0)
    end
    r[#r+1] = uint8ToLittleEndian(responseType)
    r[#r+1] = uint8ToLittleEndian(errorCode)
    r[#r+1] = uint32ToLittleEndian(requestId)
    conn:send(table.concat(r))

    if body ~= nil then
        conn:send(body)
    end
end

local function responseCheckpointInfo(requestId, checkpt, hit)
    local r = {}

    r[#r+1] = uint32ToLittleEndian(checkpt.num)
    r[#r+1] = boolToLittleEndian(hit)

    r[#r+1] = uint16ToLittleEndian(checkpt.start)
    r[#r+1] = uint16ToLittleEndian(checkpt.finish)
    r[#r+1] = boolToLittleEndian(checkpt.stop)
    r[#r+1] = boolToLittleEndian(checkpt.enabled)
    r[#r+1] = uint8ToLittleEndian(checkpt.op)
    r[#r+1] = boolToLittleEndian(checkpt.temp)

    r[#r+1] = uint32ToLittleEndian(checkpt.hitCount)
    r[#r+1] = uint32ToLittleEndian(checkpt.ignoreCount)
    r[#r+1] = boolToLittleEndian(checkpt.condition ~= nil)
    r[#r+1] = uint32ToLittleEndian(checkpt.memspace)

    response(responseType.CHECKPOINT_INFO, errorType.OK, requestId, table.concat(r))
end

local function responseRegisterInfo(requestId)
    local r = {}
    local regs = emu.getState().cpu

    local count = 0
    for name, meta in pairs(regMeta) do
        count = count + 1
    end

    r[#r+1] = uint16ToLittleEndian(count)

    local itemSize = 3
    for name, meta in pairs(regMeta) do
        r[#r+1] = uint8ToLittleEndian(itemSize)
        r[#r+1] = uint8ToLittleEndian(meta.id)
        r[#r+1] = uint16ToLittleEndian(regs[name])
    end

    response(responseType.REGISTER_INFO, errorType.OK, requestId, table.concat(r))
end

local function responseStopped()
    local pc = emu.getState().cpu.pc

    response(responseType.STOPPED, errorType.OK, EVENT_ID, uint16ToLittleEndian(pc))
end

local function responseResumed()
    local pc = emu.getState().cpu.pc

    response(responseType.RESUMED, errorType.OK, EVENT_ID, uint16ToLittleEndian(pc))
end

local function monitorOpened()
    responseRegisterInfo(EVENT_ID)
    responseStopped(EVENT_ID)
end

local function monitorClosed()
    responseRegisterInfo(EVENT_ID)
    responseResumed(EVENT_ID)
end

local function errorResponse(errorCode, requestId)
    response(0, errorCode, requestId, nil)
end

local function processPing(command)
    response(responseType.PING, errorType.OK, command.requestId, nil)
end

local function processExit(command)
    running = true

    response(responseType.EXIT, errorType.OK, command.requestId, nil)

    monitorClosed()
end

local nextTrap = 1
local traps = {}
local operation = {
    READ  = 0x01,
    WRITE = 0x02,
    EXEC  = 0x04,
}

local trapHandle

local function addCheckpoint(start, finish, stop, enabled, op, temp)
    local num = nextTrap
    nextTrap = nextTrap+1
    local trap = {
        start = start,
        finish = finish,
        stop = stop,
        enabled = enabled,
        op = op,
        temp = temp,
        hitCount = 0,
        ignoreCount = 0,
        condition = nil,
        memspace = 0,
        num = num,
    }
    traps[#traps+1] = trap

    if trap.op & operation.EXEC ~= 0 then
        trap.execRegistration = emu.addMemoryCallback(function()
            trapHandle(trap)
        end, emu.memCallbackType.cpuExec, trap.start, trap.finish)
    end
    if trap.op & operation.READ ~= 0 then
        trap.readRegistration = emu.addMemoryCallback(function()
            trapHandle(trap)
        end, emu.memCallbackType.cpuRead, trap.start, trap.finish)
    end
    if trap.op & operation.WRITE ~= 0 then
        trap.writeRegistration = emu.addMemoryCallback(function()
            trapHandle(trap)
        end, emu.memCallbackType.cpuRead, trap.start, trap.finish)
    end
    return trap
end

local function removeCheckpoint(num)
    local trap
    for i=#traps,1,-1 do
        trap = traps[i]
        if trap.num == num then
            table.remove(traps, i)
            break
        end
        trap = nil
    end

    if trap == nil then
        return false
    end

    if trap.execRegistration ~= nil then
        emu.removeMemoryCallback(trap.execRegistration, emu.memCallbackType.cpuExec, trap.start, trap.finish)
    end
    if trap.readRegistration ~= nil then
        emu.removeMemoryCallback(trap.readRegistration, emu.memCallbackType.cpuRead, trap.start, trap.finish)
    end
    if trap.writeRegistration ~= nil then
        emu.removeMemoryCallback(trap.writeRegistration, emu.memCallbackType.cpuWrite, trap.start, trap.finish)
    end

    return true
end

local function processCheckpointSet(command)
    if command.length < 8 then
        errorResponse(errorType.CMD_INVALID_LENGTH, command.requestId)
        return
    end

    -- Ignore the memspace - byte 9
    local checkpt = addCheckpoint(
        readUint16(command.body, 1),
        readUint16(command.body, 3),
        readBool(command.body, 5),
        readBool(command.body, 6),
        readUint8(command.body, 7),
        readBool(command.body, 8)
    )

    responseCheckpointInfo(command.requestId, checkpt, 0)
end

local function processCheckpointDelete(command)
    if command.length < 4 then
        errorResponse(errorType.CMD_INVALID_LENGTH, command.requestId)
        return
    end
    
    local brkNum = readUint32(command.body, 1)
    local success = removeCheckpoint(brkNum)

    if not success then
        errorResponse(errorType.OBJECT_MISSING, command.requestId)
        return
    end

    response(responseType.CHECKPOINT_DELETE, errorType.OK, command.requestId, nil)
end

local function processCheckpointList(command)
    for i = 1,#traps,1 do
        responseCheckpointInfo(command.requestId, traps[i], false);
    end

    local r = uint32ToLittleEndian(#traps)

    response(responseType.CHECKPOINT_LIST, errorType.OK, command.requestId, r);
end

local function processCommand(apiVersion, bodyLength, remainingHeader, body)
    local command = {}
    command.apiVersion = apiVersion
    if command.apiVersion < 0x01 or command.apiVersion > 0x02 then
        errorResponse(errorType.INVALID_API_VERSION, command.requestId)
    end

    command.length = bodyLength

    command.requestId = readUint32(remainingHeader, 1)
    command.type = readUint8(remainingHeader, 5)
    command.body = body

    print(string.format("Command type: %02x", command.type))

    local ct = command.type

    if ct == commandType.CHECKPOINT_SET then
        processCheckpointSet(command)
    elseif ct == commandType.CHECKPOINT_DELETE then
        processCheckpointDelete(command)
    elseif ct == commandType.CHECKPOINT_LIST then
        processCheckpointList(command)
    elseif ct == commandType.PING then
        processPing(command)
    elseif ct == commandType.EXIT then
        processExit(command)
    else
        errorResponse(errorType.CMD_INVALID_TYPE, command.requestId)
        print(string.format("unknown command: %d, skipping command length %d", command.type, command.length))
    end
end

local function prepareCommand()
    if conn == nil then
        running = true
        return
    end

    if running then
        conn:settimeout(0)
    else
        conn:settimeout(-1)
    end

    local data, status, partial = conn:receive(1)
    if status == "timeout" then
        return
    elseif status == "closed" then
        conn = nil
        running = true
        return
    end

    if data:byte(1) ~= 0x02 then
        return
    end

    if running then
        running = false
        monitorOpened()
    end
    conn:settimeout(-1)

    data, status = conn:receive(1 + 4)

    local apiVersion = readUint8(data, 1)

    print(string.format("API Version: %02x", apiVersion))

    local bodyLength = readUint32(data, 2)

    print(string.format("Body Size: %x", bodyLength))

    local remainingHeaderSize = 5

    local remainingHeader, status = conn:receive(remainingHeaderSize)

    local body
    if bodyLength > 0 then
        body, status = conn:receive(bodyLength)
    end

    processCommand(apiVersion, bodyLength, remainingHeader, body)
end

local function initConnection()
    if conn == nil then
        conn, err = server:accept()
        if conn == nil or err ~= nil then
            return
        end
    end
end

local deregisterFrameCallback
local registerFrameCallback
local function frameHandle()
    initConnection()

    if conn == nil then
        return
    end

    prepareCommand()
    if not running then
        deregisterFrameCallback()
        emu.breakExecution()
        registerFrameCallback()
    end
end

local frameCallback = nil
function registerFrameCallback()
    frameCallback = emu.addEventCallback(frameHandle, emu.eventType.inputPolled)
end

function deregisterFrameCallback() 
    emu.removeEventCallback(frameCallback, emu.eventType.inputPolled)
end

function trapHandle(trap)
    if conn == nil then
        return
    end

    running = false

    responseCheckpointInfo(requestId, trap, true)
    if not trap.stop then
        return
    end
    monitorOpened()

    deregisterFrameCallback()
    emu.breakExecution()
    registerFrameCallback()
end

local function breakHandle()
    repeat
        prepareCommand()
    until running

    emu.resume()
end

registerFrameCallback()

emu.addEventCallback(breakHandle, emu.eventType.codeBreak)