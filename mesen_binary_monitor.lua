local _p = print
local function print(data)
  _p(data .. "")
end

local baseDir = os.getenv("MESEN_REMOTE_BASEDIR")

local server = dofile(baseDir.."/server.lua")

local host = os.getenv("MESEN_REMOTE_HOST") or "localhost"
local port = os.getenv("MESEN_REMOTE_PORT") or 9355
local wait = os.getenv("MESEN_REMOTE_WAIT") == "1"

server.start(host, port, wait)