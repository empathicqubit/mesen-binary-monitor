local _p = print
local function print(data)
  _p(data .. "")
end

return function(server)
    local me = {
        open = false,
    }

    local function responseCheckpointInfo(requestId, checkpt, hit)
        local r = {}

        r[#r+1] = server.uint32ToLittleEndian(checkpt.num)
        r[#r+1] = server.boolToLittleEndian(hit)

        r[#r+1] = server.uint16ToLittleEndian(checkpt.start)
        r[#r+1] = server.uint16ToLittleEndian(checkpt.finish)
        r[#r+1] = server.boolToLittleEndian(checkpt.stop)
        r[#r+1] = server.boolToLittleEndian(checkpt.enabled)
        r[#r+1] = server.uint8ToLittleEndian(checkpt.op)
        r[#r+1] = server.boolToLittleEndian(checkpt.temp)

        r[#r+1] = server.uint32ToLittleEndian(checkpt.hitCount)
        r[#r+1] = server.uint32ToLittleEndian(checkpt.ignoreCount)
        r[#r+1] = server.boolToLittleEndian(checkpt.condition ~= nil)
        r[#r+1] = server.uint32ToLittleEndian(checkpt.memspace)

        server.response(server.responseType.CHECKPOINT_INFO, server.errorType.OK, requestId, table.concat(r))
    end

    local regMeta = {
        a =  { name = "A",  id = 0, size = 1 },
        x =  { name = "X",  id = 1, size = 1 },
        y =  { name = "Y",  id = 2, size = 1 },
        pc = { name = "PC", id = 3, size = 2 },
        sp =  { name = "SP", id = 4, size = 1 },
        status =  { name = "FL", id = 5, size = 1 },
    }

    local function responseRegisterInfo(requestId)
        if requestId == nil then
            error("request id was nil", 2)
        end

        local r = {}
        local regs = emu.getState().cpu

        local count = 0
        for name, meta in pairs(regMeta) do
            count = count + 1
        end

        r[#r+1] = server.uint16ToLittleEndian(count)

        local itemSize = 3
        for name, meta in pairs(regMeta) do
            r[#r+1] = server.uint8ToLittleEndian(itemSize)
            r[#r+1] = server.uint8ToLittleEndian(meta.id)
            r[#r+1] = server.uint16ToLittleEndian(regs[name])
        end

        server.response(server.responseType.REGISTER_INFO, server.errorType.OK, requestId, table.concat(r))
    end

    local function responseStopped()
        local pc = emu.getState().cpu.pc

        server.response(server.responseType.STOPPED, server.errorType.OK, server.EVENT_ID, server.uint16ToLittleEndian(pc))
    end

    local function responseResumed()
        local pc = emu.getState().cpu.pc

        server.response(server.responseType.RESUMED, server.errorType.OK, server.EVENT_ID, server.uint16ToLittleEndian(pc))
    end

    function me.monitorOpened()
        if me.open then
            return
        end
        me.open = true
        print("Monitor opened")

        local pc = emu.getState().cpu.pc
        print(string.format("PC: %04x", pc))

        responseRegisterInfo(server.EVENT_ID)
        responseStopped(server.EVENT_ID)
    end

    function me.monitorClosed()
        if not me.open then
            return
        end
        me.open = false
        print("Monitor closed")
        responseResumed(server.EVENT_ID)
    end

    local dumps = {}
    local function processDump(command)
        if command.length < 3 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local saveRoms = server.readBool(command.body, 1)
        local saveDisks = server.readBool(command.body, 2)
        local filenameLength = server.readUint8(command.body, 3)

        if command.length < 3 + filenameLength then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local filename = command.body:sub(4, 4 + filenameLength - 1)

        print("Dumping "..filename)

        local dereg
        local callback = function()
            dumps[filename] = emu.saveSavestate()
            server.response(server.responseType.DUMP, server.errorType.OK, command.requestId, nil)

            print("Dumped "..filename)

            emu.removeEventCallback(dereg, emu.eventType.startFrame)
        end

        dereg = emu.addEventCallback(callback, emu.eventType.startFrame)
    end

    local function processUndump(command)
        if command.length < 1 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local filenameLength = server.readUint8(command.body, 1)

        if command.length < 1 + filenameLength then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local filename = command.body:sub(2, 2 + filenameLength - 1)

        local dump = dumps[filename]
        if dump == nil then
            server.errorResponse(server.errorType.CMD_FAILURE, command.requestId)
            return
        end

        local dereg
        local callback = function()
            emu.loadSavestate(dump)

            local pc = emu.getState().cpu.pc
            server.response(server.responseType.UNDUMP, server.errorType.OK, command.requestId, server.uint16ToLittleEndian(pc))
            emu.removeEventCallback(dereg, emu.eventType.startFrame)
        end

        dereg = emu.addEventCallback(callback, emu.eventType.startFrame)
    end

    local function processAdvanceInstructions(command)
        if command.length < 3 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local stepOverSubroutines = server.readBool(command.body, 1)
        local count = server.readUint16(command.body, 2)

        server.stepping = true
        if stepOverSubroutines then
            -- FIXME
            emu.execute(count, emu.executeCountType.cpuInstructions)
        else
            emu.execute(count, emu.executeCountType.cpuInstructions)
        end

        server.running = true

        server.response(server.responseType.ADVANCE_INSTRUCTIONS, server.errorType.OK, command.requestId, nil)

        me.monitorClosed()
    end

    local function processPing(command)
        server.response(server.responseType.PING, server.errorType.OK, command.requestId, nil)
    end

    local memspaces = {
        MAIN = 0,
        INVALID = -1,
    }

    local function getRequestedMemspace(requestedMemspace)
        if requestedMemspace == 0 then
            return memspaces.MAIN
        else
            return memspaces.INVALID
        end
    end

    local banks = {
        default = 0,
        cpu = 1,
        ppu = 2,
        palette = 3,
        oam = 4,
        secondaryOam = 5
    }

    local function validateBanknum(memspace, banknum)
        return memspace == memspaces.MAIN and banknum >= banks.default and banknum <= banks.secondaryOam
    end

    local function ignoreRegister(meta)
        return false
    end

    local function processRegistersAvailable(command)
        if command.length < 1 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local requestedMemspace = server.readUint8(command.body, 1)
        local memspace = getRequestedMemspace(requestedMemspace)

        if memspace == memspaces.INVALID then
            server.errorResponse(server.errorType.INVALID_MEMSPACE, command.requestId)
            return
        end

        local responseRegCount = 0;

        for name, meta in pairs(regMeta) do
            if not ignoreRegister(meta) then
                responseRegCount = responseRegCount + 1
            end
        end

        local r = {}

        r[#r+1] = server.uint16ToLittleEndian(responseRegCount)

        for name, meta in pairs(regMeta) do
            if not ignoreRegister(meta) then
                local itemSize = meta.name:len() + 3

                r[#r+1] = server.uint8ToLittleEndian(itemSize)
                r[#r+1] = server.uint8ToLittleEndian(meta.id)
                r[#r+1] = server.uint8ToLittleEndian(meta.size * 8)
                r[#r+1] = server.writeString(meta.name);
            end
        end

        server.response(server.responseType.REGISTERS_AVAILABLE, server.errorType.OK, command.requestId, table.concat(r));
    end

    local function processBanksAvailable(command)
        local responseBankCount = 0;

        for name, id in pairs(banks) do
            responseBankCount = responseBankCount + 1
        end

        local r = {}

        r[#r+1] = server.uint16ToLittleEndian(responseBankCount)

        for name, id in pairs(banks) do
            local itemSize = name:len() + 3

            r[#r+1] = server.uint8ToLittleEndian(itemSize)
            r[#r+1] = server.uint16ToLittleEndian(id)
            r[#r+1] = server.writeString(name);
        end

        server.response(server.responseType.BANKS_AVAILABLE, server.errorType.OK, command.requestId, table.concat(r));
    end

    local function processDisplayGet(command)
        print("Taking screenshot")
        if command.apiVersion < 0x02 then
            print("API Version error")
            server.errorResponse(server.errorType.INVALID_API_VERSION, command.requestId)
            return
        end

        local infoLength = 13;

        local shot = emu.takeScreenshot()
        print("Screenshot taken")

        local r = {}

        -- Length of fields before display buffer
        r[#r+1] = server.uint32ToLittleEndian(infoLength)

        -- Full width of buffer
        r[#r+1] = server.uint16ToLittleEndian(256)
        -- Full height of buffer
        r[#r+1] = server.uint16ToLittleEndian(240)
        -- X offset of the inner part of the screen
        r[#r+1] = server.uint16ToLittleEndian(0)
        -- Y offset of the inner part of the screen
        r[#r+1] = server.uint16ToLittleEndian(0)
        -- Width of the inner part of the screen
        r[#r+1] = server.uint16ToLittleEndian(256)
        -- Height of the inner part of the screen
        r[#r+1] = server.uint16ToLittleEndian(240)
        -- Bits per pixel of image
        r[#r+1] = server.uint8ToLittleEndian(24)

        -- Length of display buffer
        r[#r+1] = server.uint32ToLittleEndian(shot:len())

        -- Buffer Data in requested format
        r[#r+1] = shot

        server.response(server.responseType.DISPLAY_GET, server.errorType.OK, command.requestId, table.concat(r));
    end

    local function processExit(command)
        server.response(server.responseType.EXIT, server.errorType.OK, command.requestId, nil)

        me.monitorClosed()

        server.running = true
    end

    local function processReset(command)
        server.running = true
        emu.reset()

        server.response(server.responseType.RESET, server.errorType.OK, command.requestId, nil)

        me.monitorClosed()
    end

    local function processMemorySet(command)
        local newSidefx = server.readBool(command.body, 1)

        local startAddress = server.readUint16(command.body, 2)
        local endAddress = server.readUint16(command.body, 4)

        if startAddress > endAddress then
            server.errorResponse(server.errorType.INVALID_PARAMETER, command.requestId)
            return
        end

        local length = endAddress - startAddress + 1

        if command.length < length + 8 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local requestedMemspace = server.readUint8(command.body, 6)
        local memspace = getRequestedMemspace(requestedMemspace)

        if memspace == memspaces.INVALID then
            server.errorResponse(server.errorType.INVALID_MEMSPACE, command.requestId)
            return
        end

        local requestedBanknum = server.readUint16(command.body, 7)

        if not validateBanknum(memspace, requestedBanknum) then
            server.errorResponse(server.errorType.INVALID_PARAMETER, command.requestId)
            return
        end

        local banknum = requestedBanknum

        if banknum == banks.default then
            banknum = banks.cpu
        end

        if not newSidefx and ( banknum == banks.cpu or banknum == banks.ppu ) then
            banknum = banknum + 0x100
        end

        banknum = banknum - 1

        for i = 0,length - 1,1 do
            local val = command.body:byte(8 + i + 1)
            print(val)
            emu.write(startAddress + i, val, banknum)
        end

        server.response(server.responseType.MEM_SET, server.errorType.OK, command.requestId, nil)
    end

    local function processExit(command)
        server.running = true

        server.response(server.responseType.EXIT, server.errorType.OK, command.requestId, nil)

        me.monitorClosed()
    end

    local function processReset(command)
        server.running = true
        emu.reset()

        server.response(server.responseType.RESET, server.errorType.OK, command.requestId, nil)

        me.monitorClosed()
    end

    local function processMemorySet(command)
        local newSidefx = server.readBool(command.body, 1)

        local startAddress = server.readUint16(command.body, 2)
        local endAddress = server.readUint16(command.body, 4)

        if startAddress > endAddress then
            server.errorResponse(server.errorType.INVALID_PARAMETER, command.requestId)
            return
        end

        local length = endAddress - startAddress + 1

        if command.length < length + 8 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local requestedMemspace = server.readUint8(command.body, 6)
        local memspace = getRequestedMemspace(requestedMemspace)

        if memspace == memspaces.INVALID then
            server.errorResponse(server.errorType.INVALID_MEMSPACE, command.requestId)
            return
        end

        local requestedBanknum = server.readUint16(command.body, 7)

        if not validateBanknum(memspace, requestedBanknum) then
            server.errorResponse(server.errorType.INVALID_PARAMETER, command.requestId)
            return
        end

        local banknum = requestedBanknum

        if banknum == banks.default then
            banknum = banks.cpu
        end

        if not newSidefx and ( banknum == banks.cpu or banknum == banks.ppu ) then
            banknum = banknum + 0x100
        end

        banknum = banknum - 1

        for i = 0,length - 1,1 do
            local val = command.body:byte(8 + i + 1)
            print(val)
            emu.write(startAddress + i, val, banknum)
        end

        server.response(server.responseType.MEM_SET, server.errorType.OK, command.requestId, nil)
    end

    local function processMemoryGet(command)
        if command.length < 8 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local newSidefx = server.readBool(command.body, 1)

        local startAddress = server.readUint16(command.body, 2)
        local endAddress = server.readUint16(command.body, 4)

        if startAddress > endAddress then
            server.errorResponse(server.errorType.INVALID_PARAMETER, command.requestId)
            return
        end

        local requestedMemspace = server.readUint8(command.body, 6)
        local memspace = getRequestedMemspace(requestedMemspace)

        if memspace == memspaces.INVALID then
            server.errorResponse(server.errorType.INVALID_MEMSPACE, command.requestId)
            return
        end

        local length = endAddress - startAddress + 1

        local requestedBanknum = server.readUint16(command.body, 7)

        if not validateBanknum(memspace, requestedBanknum) then
            server.errorResponse(server.errorType.INVALID_PARAMETER, command.requestId)
            return
        end

        local banknum = requestedBanknum

        local r = {}

        r[#r+1] = server.uint16ToLittleEndian(length)

        if banknum == banks.default then
            banknum = banks.cpu
        end

        if not newSidefx and ( banknum == banks.cpu or banknum == banks.ppu ) then
            banknum = banknum + 0x100
        end

        banknum = banknum - 1

        local remainingByte = length % 2 ~= 0
        for addr=startAddress,endAddress-1,2 do
            r[#r+1] = server.uint16ToLittleEndian(emu.readWord(addr, banknum))
        end
        if remainingByte then
            r[#r+1] = server.uint8ToLittleEndian(emu.read(addr, banknum))
        end

        server.response(server.responseType.MEM_GET, server.errorType.OK, command.requestId, table.concat(r))
    end

    nextTrap = 1
    traps = {}
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
                if trap.enabled then
                    trapHandle(trap)
                end
            end, emu.memCallbackType.cpuExec, trap.start, trap.finish)
        end
        if trap.op & operation.READ ~= 0 then
            trap.readRegistration = emu.addMemoryCallback(function()
                if trap.enabled then
                    trapHandle(trap)
                end
            end, emu.memCallbackType.cpuRead, trap.start, trap.finish)
        end
        if trap.op & operation.WRITE ~= 0 then
            trap.writeRegistration = emu.addMemoryCallback(function()
                if trap.enabled then
                    trapHandle(trap)
                end
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

    local function toggleCheckpoint(enable, num)
        for i=#traps,1,-1 do
            trap = traps[i]
            if trap.num == num then
                break
            end
            trap = nil
        end

        if trap == nil then
            return false
        end

        trap.enabled = enable

        return true
    end

    local function processCheckpointGet(command)
        if command.length < 4 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local num = server.readUint32(command.body, 1)

        for i=#traps,1,-1 do
            trap = traps[i]
            if trap.num == num then
                break
            end
            trap = nil
        end

        if not trap then
            server.errorResponse(server.errorType.OBJECT_MISSING, command.requestId)
            return
        end

        responseCheckpointInfo(command.requestId, trap, false)
    end

    local function processCheckpointSet(command)
        if command.length < 8 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        -- Ignore the memspace - byte 9
        local checkpt = addCheckpoint(
            server.readUint16(command.body, 1),
            server.readUint16(command.body, 3),
            server.readBool(command.body, 5),
            server.readBool(command.body, 6),
            server.readUint8(command.body, 7),
            server.readBool(command.body, 8)
        )

        responseCheckpointInfo(command.requestId, checkpt, 0)
    end

    local function processCheckpointDelete(command)
        if command.length < 4 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end
        
        local brkNum = server.readUint32(command.body, 1)
        local success = removeCheckpoint(brkNum)

        if not success then
            server.errorResponse(server.errorType.OBJECT_MISSING, command.requestId)
            return
        end

        server.response(server.responseType.CHECKPOINT_DELETE, server.errorType.OK, command.requestId, nil)
    end

    local function processCheckpointList(command)
        for i = 1,#traps,1 do
            responseCheckpointInfo(command.requestId, traps[i], false)
        end

        local r = server.uint32ToLittleEndian(#traps)

        server.response(server.responseType.CHECKPOINT_LIST, server.errorType.OK, command.requestId, r)
    end

    local function processCheckpointToggle(command)
        if command.length < 5 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local num = server.readUint32(command.body, 1)
        local enable = server.readBool(command.body, 5)
        
        if not toggleCheckpoint(enable, num) then
            server.errorResponse(server.errorType.OBJECT_MISSING, command.requestId)
            return
        end

        server.response(server.responseType.CHECKPOINT_TOGGLE, server.errorType.OK, command.requestId, nil)
    end

    local function validateRegister(memspace, regId)
        return memspace == memspaces.MAIN and regId >= regMeta.a.id and regId <= regMeta.status.id
    end

    local function processRegistersGet(command)
        if command.length < 1 then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local requestedMemspace = server.readUint8(command.body, 1)
        local memspace = getRequestedMemspace(requestedMemspace)

        if memspace == memspaces.INVALID then
            server.errorResponse(server.errorType.INVALID_MEMSPACE, command.requestId)
            return
        end

        responseRegisterInfo(command.requestId, memspace)
    end

    local function processRegistersSet(command)
        local headerSize = 3
        local count = server.readUint16(command.body, 2)

        if command.length < headerSize + count * (3 + 1) then
            server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
            return
        end

        local requestedMemspace = server.readUint8(command.body, 1)
        local memspace = getRequestedMemspace(requestedMemspace)

        if memspace == memspaces.INVALID then
            server.errorResponse(server.errorType.INVALID_MEMSPACE, command.requestId)
            return
        end

        local bodyCursor = headerSize + 1

        local state = emu.getState()
        for i=1,count do
            local itemSize = server.readUint8(command.body, bodyCursor + 0)
            local regId = server.readUint8(command.body, bodyCursor + 1)
            local regVal = server.readUint16(command.body, bodyCursor + 2)

            if itemSize < 3 then
                server.errorResponse(server.errorType.CMD_INVALID_LENGTH, command.requestId)
                return
            end

            if not validateRegister(memspace, regId) then
                server.errorResponse(server.errorType.OBJECT_MISSING, command.requestId)
                return
            end

            for name, meta in pairs(regMeta) do
                if meta.id == regId then
                    state.cpu[name] = regVal
                    break
                end
            end

            bodyCursor = bodyCursor + itemSize + 1
        end

        emu.setState(state)

        responseRegisterInfo(command.requestId, memspace)
    end

    function me.processCommand(apiVersion, bodyLength, remainingHeader, body)
        local command = {}
        command.apiVersion = apiVersion
        if command.apiVersion < 0x01 or command.apiVersion > 0x02 then
            server.errorResponse(server.errorType.INVALID_API_VERSION, command.requestId)
        end

        command.length = bodyLength

        command.requestId = server.readUint32(remainingHeader, 1)
        command.type = server.readUint8(remainingHeader, 5)
        command.body = body

        local prettyType = ""
        for k, v in pairs(server.commandType) do
            if v == command.type then
                prettyType = k
                break
            end
        end

        print(string.format("Command start: %02x (%s)", command.type, prettyType))

        local ct = command.type

        if ct == server.commandType.MEM_GET then
            processMemoryGet(command)
        elseif ct == server.commandType.MEM_SET then
            processMemorySet(command)

        elseif ct == server.commandType.CHECKPOINT_GET then
            processCheckpointGet(command)
        elseif ct == server.commandType.CHECKPOINT_SET then
            processCheckpointSet(command)
        elseif ct == server.commandType.CHECKPOINT_DELETE then
            processCheckpointDelete(command)
        elseif ct == server.commandType.CHECKPOINT_LIST then
            processCheckpointList(command)
        elseif ct == server.commandType.CHECKPOINT_TOGGLE then
            processCheckpointToggle(command)

        elseif ct == server.commandType.REGISTERS_GET then
            processRegistersGet(command)
        elseif ct == server.commandType.REGISTERS_SET then
            processRegistersSet(command)

            --[[
        elseif ct == server.commandType.DUMP then
            processDump(command)
        elseif ct == server.commandType.UNDUMP then
            processUndump(command)
            ]]

        elseif ct == server.commandType.ADVANCE_INSTRUCTIONS then
            processAdvanceInstructions(command)

        elseif ct == server.commandType.PING then
            processPing(command)
        elseif ct == server.commandType.REGISTERS_AVAILABLE then
            processRegistersAvailable(command)
        elseif ct == server.commandType.BANKS_AVAILABLE then
            processBanksAvailable(command)
        elseif ct == server.commandType.DISPLAY_GET then
            processDisplayGet(command)

        elseif ct == server.commandType.EXIT then
            processExit(command)
        elseif ct == server.commandType.RESET then
            processReset(command)
        else
            server.errorResponse(server.errorType.CMD_INVALID_TYPE, command.requestId)
            print(string.format("unknown command: %d, skipping command length %d", command.type, command.length))
        end

        print(string.format("Command finished: %02x", command.type))
    end

    function trapHandle(trap)
        if server.conn == nil then
            return
        end

        responseCheckpointInfo(server.EVENT_ID, trap, true)
        if trap.stop then
            me.monitorOpened()
        else
            return
        end

        if server.running then
            server.running = false
            server.deregisterFrameCallback()
            print("Break called by trap")
            emu.breakExecution()
        else
            print("Server not running")
        end
    end

    return me
end