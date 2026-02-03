-- Test: can we capture exit code from async wrapper?

-- 1) Write a command that will FAIL
local f1 = io.open("/tmp/fail_cmd.sh", "w")
f1:write("ls /nonexistent_xyz_123\n")
f1:close()

-- 2) Write a command that will SUCCEED
local f2 = io.open("/tmp/ok_cmd.sh", "w")
f2:write("echo hello_world\n")
f2:close()

-- 3) Write wrapper for FAIL case
local w1 = io.open("/tmp/wrap_fail.sh", "w")
w1:write("if sh /tmp/fail_cmd.sh > /tmp/fail_out.txt\n")
w1:write("then\n")
w1:write("echo 0 > /tmp/fail_ec.txt\n")
w1:write("else\n")
w1:write("echo 1 > /tmp/fail_ec.txt\n")
w1:write("fi\n")
w1:close()

-- 4) Write wrapper for OK case
local w2 = io.open("/tmp/wrap_ok.sh", "w")
w2:write("if sh /tmp/ok_cmd.sh > /tmp/ok_out.txt\n")
w2:write("then\n")
w2:write("echo 0 > /tmp/ok_ec.txt\n")
w2:write("else\n")
w2:write("echo 1 > /tmp/ok_ec.txt\n")
w2:write("fi\n")
w2:close()

-- Verify file content
print("=== wrapper content ===")
local vf = io.open("/tmp/wrap_fail.sh", "r")
print(vf:read("*a"))
vf:close()

-- 5) Run both wrappers in background
print("=== Running wrappers in bg ===")
os.execute("sh /tmp/wrap_fail.sh &")
os.execute("sh /tmp/wrap_ok.sh &")

-- 6) Wait
print("=== Waiting 3s ===")
os.execute("sleep 3")

-- 7) Read results
print("=== Results ===")
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "FILE NOT FOUND" end
    local s = f:read("*a")
    f:close()
    return s
end

print("FAIL exit code: " .. read_file("/tmp/fail_ec.txt"))
print("FAIL output: " .. read_file("/tmp/fail_out.txt"))
print("OK exit code: " .. read_file("/tmp/ok_ec.txt"))
print("OK output: " .. read_file("/tmp/ok_out.txt"))
