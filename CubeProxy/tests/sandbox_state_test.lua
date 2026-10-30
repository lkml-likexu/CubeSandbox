package.path = "./lua/?.lua;" .. package.path

local state_value
local captures
local exited

package.loaded["utils"] = {
    respond_unavailable = function()
        error({ status = 503 }, 0)
    end,
    respond_gone = function()
        error({ status = 410 }, 0)
    end,
}

ngx = {
    WARN = "WARN",
    ERR = "ERR",
    HTTP_OK = 200,
    HTTP_POST = "POST",
    var = {
        cube_sidecar_addr = "127.0.0.1:8083",
        http_x_cube_request_id = "request-1",
    },
    header = {},
    shared = {
        cube_sandbox_state = {
            get = function(_, _)
                return state_value
            end,
            set = function(_, _, value)
                state_value = value
            end,
        },
    },
    escape_uri = function(value)
        return value
    end,
    log = function() end,
    location = {
        capture = function(path, options)
            captures = captures + 1
            assert(path == "/_sidecar_resume")
            assert(options.method == ngx.HTTP_POST)
            assert(options.args == "sandbox_id=sbx&request_id=request-1")
            assert(options.body == "")
            return { status = ngx.HTTP_OK, body = "" }
        end,
    },
}

local sandbox_state = require "sandbox_state"

local function run(initial)
    state_value = initial
    captures = 0
    exited = nil
    return pcall(sandbox_state.gate, "sbx")
end

local ok, err = run("running")
assert(ok and err == nil)
assert(captures == 0)

ok, err = run("paused")
assert(ok and err == nil)
assert(captures == 1)
assert(state_value == "running")

ok, err = run("pausing")
assert(ok and err == nil)
assert(captures == 1)
assert(state_value == "running")

ok, err = run("killed")
assert(not ok and type(err) == "table" and err.status == 410)
assert(captures == 0)

ngx.location.capture = function()
    captures = captures + 1
    return { status = 500, body = "resume failed" }
end
ok, err = run("paused")
assert(not ok and type(err) == "table" and err.status == 503)
assert(captures == 1)

print("sandbox_state_test: ok")
