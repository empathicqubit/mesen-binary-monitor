local _p = print
local function print(data)
  _p(data .. "")
end

local baseDir = os.getenv("MESEN_REMOTE_BASEDIR")

local socket = require("socket.core")
local me = {}
local commands = dofile(baseDir.."/commands.lua")(me)

me.running = false
me.stepping = false
me.conn = nil
me.server = nil

function me.boolToLittleEndian(b)
    local value = 0
    if b then
        value = 1
    end
    return string.char(value & 0xff)
end

function me.uint8ToLittleEndian(value)
    if value == nil then
        error("value is nil", 2)
    end
    return string.char(value & 0xff)
end

function me.uint16ToLittleEndian(value)
    if value == nil then
        error("value is nil", 2)
    end
    return string.char(value & 0xff, (value >> 8) & 0xff)
end

function me.uint32ToLittleEndian(value)
    if value == nil then
        error("value is nil", 2)
    end
    return string.char(value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >> 24) & 0xff)
end

function me.writeString(value)
    if value == nil then
        error("value is nil", 2)
    end
    return me.uint8ToLittleEndian(value:len()) .. value
end

function me.readUint32(data, index)
    return data:byte(index) + (data:byte(index + 1) << 8) + (data:byte(index + 2) << 16) + (data:byte(index + 3) << 24)
end

function me.readUint16(data, index)
    return data:byte(index) + (data:byte(index + 1) << 8)
end

function me.readUint8(data, index)
    return data:byte(index)
end

function me.readBool(data, index)
    return data:byte(index) > 0
end

me.errorType = {
    OK = 0x00,
    OBJECT_MISSING = 0x01,
    INVALID_MEMSPACE = 0x02,
    CMD_INVALID_LENGTH = 0x80,
    INVALID_PARAMETER = 0x81,
    CMD_INVALID_API_VERSION = 0x82,
    CMD_INVALID_TYPE = 0x83,
    CMD_FAILURE = 0x8f,
};

me.commandType = {
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

me.responseType = {
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

me.API_VERSION = 0x02

me.EVENT_ID = 0xffffffff

function me.response(responseType, errorCode, requestId, body)
    if responseType == nil or errorCode == nil or requestId == nil then
        error("A required response value was nil", 2)
    end

    if me.conn == nil then
        return
    end

    local r = {}
    r[#r+1] = string.char(0x02)
    r[#r+1] = me.uint8ToLittleEndian(me.API_VERSION)
    if body ~= nil then
        r[#r+1] = me.uint32ToLittleEndian(body:len())
    else
        r[#r+1] = me.uint32ToLittleEndian(0)
    end
    r[#r+1] = me.uint8ToLittleEndian(responseType)
    r[#r+1] = me.uint8ToLittleEndian(errorCode)
    r[#r+1] = me.uint32ToLittleEndian(requestId)
    me.conn:send(table.concat(r))

    if body ~= nil then
        me.conn:send(body)
    end
end

function me.errorResponse(errorCode, requestId)
    me.response(0, errorCode, requestId, nil)
end

local function initConnection()
    if me.conn == nil then
        me.conn, err = me.server:accept()
        if me.conn == nil or err ~= nil then
            return
        end
        print("Connected")
    end
end

local function prepareCommand()
    if me.conn == nil then
        me.running = true
        return
    end

    if me.running then
        me.conn:settimeout(0)
    else
        me.conn:settimeout(-1)
    end

    local data, status, partial = me.conn:receive(1)
    if status == "timeout" then
        return
    elseif status == "closed" then
        me.conn = nil
        me.running = true
        return
    end

    if data:byte(1) ~= 0x02 then
        return
    end

    if me.running then
        me.running = false
        commands.monitorOpened()
    end
    me.conn:settimeout(-1)

    data, status = me.conn:receive(1 + 4)

    local apiVersion = me.readUint8(data, 1)

    local bodyLength = me.readUint32(data, 2)

    local remainingHeaderSize = 5

    local remainingHeader, status = me.conn:receive(remainingHeaderSize)

    local body
    if bodyLength > 0 then
        body, status = me.conn:receive(bodyLength)
    end

    commands.processCommand(apiVersion, bodyLength, remainingHeader, body)
end

me.deregisterFrameCallback = nil
me.registerFrameCallback = nil
local function frameHandle()
    initConnection()

    if me.conn == nil then
        return
    end

    prepareCommand()
    if not me.running then
        me.deregisterFrameCallback()
        emu.breakExecution()
        me.registerFrameCallback()
    end
end

local frameCallback = nil
function me.registerFrameCallback()
    frameCallback = emu.addEventCallback(frameHandle, emu.eventType.inputPolled)
end

function me.deregisterFrameCallback() 
    emu.removeEventCallback(frameCallback, emu.eventType.inputPolled)
end

local function breakHandle()
    print("Break")

    if me.stepping then
        me.stepping = false
        commands.monitorOpened()
    end

    repeat
        prepareCommand()
    until me.running

    emu.resume()
end

function me.start(host, port, waitForConnection)
    me.stepping = false
    me.running = true

    print("Binding to host '" ..host.. "' and port " ..port.. "...")

    me.server = assert(socket.tcp())
    assert(me.server:bind(host, port))
    assert(me.server:listen(32))
    if waitForConnection then
        me.server:settimeout(-1)
    else
        me.server:settimeout(0)
    end

    local i, p   = me.server:getsockname()
    assert(i, p)

    print("Waiting for connection on " .. i .. ":" .. p .. "...")

    me.registerFrameCallback()

    emu.addEventCallback(breakHandle, emu.eventType.codeBreak)

    emu.breakExecution()
end

return me