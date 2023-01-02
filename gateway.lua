#!/usr/bin/lua

local VERSION_NAME = "0.0.5 21-6-2020"


require "iwinfo"
-- load driver
local luasql_driver = require "luasql.mysql"

-- globals
local device = "wlan0"
local CHECK_NETWORK_CONNECTION_POLLING_TIME = 5
local SEND_STATUS_CHECK_UPDATE_INTERVAL_SECS = 600 -- TODO: change to 3600 
local LAST_USER_DISCONNECTED_CELLULAR_SUSPENSION_INTERVAL_SECS = 30 -- TODO: change to 600
local CELLULAR_POWER_CONTROL_GPIO = "21"
local SYSTEM_POWER_CONTROL_GPIO = "20"
local DATA_GPIO = "20"
local SCL_GPIO = "22"
local GPIO_NUMBER_OF_START_BITS = 2
local GPIO_NUMBER_OF_DATA_BITS = 16
local GPIO_PARAMETER_SHIFTER = 16
local GPIO_SLEEP_COMMAND = 3
local GPIO_KEEP_ALIVE_COMMAND = 12  -- 0xC
local GPIO_SEND_KEEP_ALIVE_INTERVAL_SECONDS = 600
local glb_gpio_last_sent_keep_alive = 0

local glb_IS_KEEP_ALIVE_ENABLED = true   


local SCRIPT_NAME_FILE = "/usr/soswifi/scriptname"
local GROUP_SETTINGS_FILE = "/usr/soswifi/groupsettings"
local STORED_RECORDS_FILE = "/tmp/soswifirecords"
local glb_last_status_update = 0 -- far in th past to get immediate status upon power up
local glb_mac_address = ""
local glb_total_wifi_seconds = 0
local glb_wifi_on_start_time = 0
local glb_powerup_time = os.time()
local glb_wifi_is_on = false
-- night mode paramters
local glb_night_mode_enabled = false
local glb_night_mode_start_time = 0  -- number of seconds from midnight
local glb_night_mode_end_time = 0  -- number of seconds from midnight
local glb_night_mode_on_seconds = 0
local glb_night_mode_off_seconds = 0
-- Daily on paramters
local glb_daily_on_mode_start_time = 0  -- number of seconds from midnight
local glb_daily_on_mode_end_time = 0  -- number of seconds from midnight
-- System off paramters
local glb_system_off_enabled = false
local glb_system_off_start_minute = 0
local glb_system_off_length_minutes = 0  -- obsolete
local glb_system_off_end_minute = 0
local glb_system_off_update_interval_minutes = 60
local TOTAL_MINUTES_PER_DAY = 60 * 24


local glb_gateways_list_size = 0
local glb_gateways_list = {} -- list of true/nil where the IP string are the index (i.e. glb_gateways_list["1.2.3.4"]=true)
local luasql_host="db.soswifi.co.il";
local luasql_port=3306;
local luasql_user="carambola001";
local luasql_password="123crmbl001123";
local luasql_dbname="soswifi_schema";

local glb_gw_ip = ""
local glb_script_file_name = ""

--  -----------------------------------------------------
--  -------------- functions  ---------------------------
--  -----------------------------------------------------
function printToSOSlog(msg) 
	os.execute("logger [soswifi] '"..msg.."'")
	print(msg) -- TODO debug condition ?
end

--  -------------- power on initializations  ---------------------------
-- initialize should NOT include values relay on network already statble 
function initialize() 
	-- define GPIO for SYSTEM power control - SCL/DATA
	local t = os.execute("echo \""..DATA_GPIO.."\" > /sys/class/gpio/export")
	t = os.execute("echo \"out\" > /sys/class/gpio/gpio"..DATA_GPIO.."/direction")
	t = os.execute("echo \""..SCL_GPIO.."\" > /sys/class/gpio/export")
	t = os.execute("echo \"out\" > /sys/class/gpio/gpio"..SCL_GPIO.."/direction")
	-- Define the I2C pins for voltmeter
	t = os.execute("insmod i2c-gpio-custom bus0=0,18,19")
	sleep(1)
	-- reset the voltmeter
	t = os.execute("i2cset -y -r 0 0x40 0 0x0080 w")
	-- printToSOSlog(t)
	FillMACAddress()
	FillScriptNameGlobal()
	-- restart netwrok service
    os.execute("/etc/init.d/network restart")
    sleep(10)
end

-- -------------- sleep in milliseconds  ---------------------------
function sleepmilli(ml)
    local s = 0
    for i=1,918*ml do s = s + i end
end

-- -------------- set GPIO bit on or off  ---------------------------
function SetGPIOBit(gpio, bitval)
    --print(gpio.."->"..bitval)
    os.execute("echo \""..bitval.."\" > /sys/class/gpio/gpio"..gpio.."/value");
end

-- -------------- get bit from x in position p  ---------------------------
function bit(p)
    return 2 ^ (p - 1)  -- 1-based indexing
end
function hasbit(x, p)
    return x % (p + p) >= p
end

--  -------------- Send value to main power switch as data over GPIO  ---------------------------
function SendDataToMainPowerSwitch(value)
   -- send start bits (two 1's)
    for i=1,GPIO_NUMBER_OF_START_BITS do
        SetGPIOBit(DATA_GPIO,"1")
        SetGPIOBit(SCL_GPIO,"1")
        sleepmilli(100)
        SetGPIOBit(DATA_GPIO,"0")
        SetGPIOBit(SCL_GPIO,"0")
        sleepmilli(100)
    end
    -- send data bits - LSB first
    for i=1,GPIO_NUMBER_OF_DATA_BITS do
        if hasbit(value, bit(i)) then
            -- print("hasbit("..value..","..i..")->1")
            SetGPIOBit(DATA_GPIO,"1")
        else
            -- print("hasbit("..value..","..i..")->0")
            SetGPIOBit(DATA_GPIO,"0")
        end
        SetGPIOBit(SCL_GPIO,"1")
        sleepmilli(100)
        SetGPIOBit(DATA_GPIO,"0")
        SetGPIOBit(SCL_GPIO,"0")
        sleepmilli(100)
    end
end

--  -------------- send keep alive to main switch ---------------------------
function SendKeepAliveToMainSwitch() 
	local now = os.time()

	if ((now - glb_gpio_last_sent_keep_alive) > GPIO_SEND_KEEP_ALIVE_INTERVAL_SECONDS) then
		glb_gpio_last_sent_keep_alive = now
		printToSOSlog("SendKeepAliveToMainSwitch - sending")   -- TODO debug remove
		SendDataToMainPowerSwitch(GPIO_KEEP_ALIVE_COMMAND) 
	end
end

--  -------------- power on or off wifi -------------------------
function PowerWiFi(is_on)
    if (glb_wifi_is_on == is_on) then
        return
    end
    glb_wifi_is_on = is_on
	printToSOSlog("PowerWiFi "..(is_on and "on" or "off"))   -- TODO debug remove
	if is_on then 
		glb_wifi_on_start_time = os.time()
		os.execute("wifi")
	else
		if (glb_wifi_on_start_time ~= 0) then
			glb_total_wifi_seconds = glb_total_wifi_seconds + os.time() - glb_wifi_on_start_time
			glb_wifi_on_start_time = 0
		end
		os.execute("wifi down")
	end
	sleep(3)
	os.execute("/etc/init.d/nodogsplash restart > /dev/null 2>&1")
	sleep(10)
end

--  -------------- read voltmeter ----------------------------------------
function GetVoltmeter() 
	local f = io.popen("i2cget -y 0 0x40 2 w") -- runs command
	local vval = f:read("*a") -- read output of command "0xcf28"
	local millivolt = 0
	-- validate result
	if (string.sub(vval, 1, 2) == "0x") then
		-- switch the bytes
		local switched = string.sub(vval, 5, 6)..string.sub(vval, 3, 4)
		millivolt = tonumber(switched,16)*1.25
	end
	f:close()
	return math.floor(millivolt)
end

--  -------------- read voltmeter ----------------------------------------
function GetAmperemeter() 
	local f = io.popen("i2cget -y 0 0x40 1 w") -- runs command
	local vval = f:read("*a") -- read output of command "0xcf28"
	local milliampere = 0
	-- validate result
	if (string.sub(vval, 1, 2) == "0x") then
		-- switch the bytes
		local switched = string.sub(vval, 5, 6)..string.sub(vval, 3, 4)
		-- this conversion assume that the number is positive
		-- [The device actually returns values in two's complement 
		--  and if the value is negative (the MSB is is set) 
		--  the bits should be inverted and the add 1 to the result]
		milliampere = tonumber(switched,16)*1.25
	end
	f:close()
	return math.floor(milliampere)
end

--  -------------- get data counters ----------------------------------------
function GetDataCounters() 
	rx_val = 0
	tx_val = 0
	rate_val = 0
	interface = "wlan0"
	local f = io.popen("vnstat -i "..interface.." --oneline") -- runs command
	-- resutl example:
	-- 1;eth1;2020-02-28;1.04 GiB;140.00 MiB;1.18 GiB;150.73 kbit/s;2020-02;1.04 GiB;140.00 MiB;1.18 GiB;4.22 kbit/s;1.04 GiB;140.00 MiB;1.18 GiB
	--  [2-if][3-today ] [4-RX  ] [5-TX    ] [6-total][7-rate     ]  
	local vval = f:read("*a") -- read output of command 
	-- parse/validate result
	arr_size, str_arr = split(vval, ";")
	if (arr_size > 7) then
		if (str_arr[2] == interface) then
			rx_val = GetCounterValue(true, str_arr[4])
			tx_val = GetCounterValue(true, str_arr[5])
			rate_val = GetCounterValue(false, str_arr[7])
		end
	end
	f:close()
	return rx_val, tx_val, rate_val
end
-- get value from is_rxtx==true, "11.04 GiB" --or--  is_rxtx==false, "150.73 kbit/s"
-- for rx and tx value is in bytes (i.e. need to divid by 8) for rate - leave it in bits value
function GetCounterValue(is_rxtx, str)
	val = 0
	factor = 1
	space_start, space_end = string.find(str, " ")
	if (space_end ~= nil) then
		pre_val = tonumber(string.sub(str, 1, space_start - 1))
		if (pre_val ~= nil) then
			size_char = string.sub(str, space_end + 1, space_end + 1)
			if (size_char == "G") then 
				factor = 1048576
			elseif (size_char == "M") then 
				factor = 1024
			elseif (size_char == "b") then 
				-- don't calculate very small values
				factor = 0
			end 
			if (factor == 0) then
				val = 1
			else
				if is_rxtx then
					val = val / 8
				end
				val = pre_val * factor
			end
		end
	end
	return math.floor(val)
end

--  -------------- split string to array by delimiter (delimiter should not be REGEX used char such as . or *) ---------------------------
function split(s, delimiter)
	result = {};
	size = 0
    for match in (s..delimiter):gmatch("(.-)"..delimiter) do
		table.insert(result, match);
		size = size + 1
    end
    return size, result;
end
--  -------------- wait for internet connection ---------------------------
-- requires opkg install luasocket
function WaitForInternetConnection()
    if not glb_wifi_is_on then -- of no wifi - no need to check
        return false
    end
	local socket = require("socket")
    local connection = socket.tcp()
    connection:settimeout(4000)  -- 4 sec
	local result = connection:connect("www.google.com", 80)
	connection:close()
	if (result) then return true end
	return false
end

-- ------------------------------------------------------------------
function AddRecordToLocalFile(record)
    local status, fp = pcall(io.open, STORED_RECORDS_FILE, 'a')
    if status then
        fp:write(record,"\n")
        fp:close()
        printToSOSlog ("Saved record  "..string.sub(record,1,10).."... sccessfully") -- TODO debug remove
    else
        printToSOSlog ("Failed to open "..STORED_RECORDS_FILE.."!!") -- TODO debug remove
    end
end

-- ------------------------------------------------------------------
-- get all rcords from records file, returns an empty list/table if the file does not exist
function ReadStoredRecords()
    if not file_exists(STORED_RECORDS_FILE) then return {} end
    lines = {}
    for line in io.lines(STORED_RECORDS_FILE) do 
      lines[#lines + 1] = line
    end
    return lines
  end
-- ------------------------------------------------------------------
function SaveGroupSettingsToFile()

	local need_to_save = false
	-- save current (new) values
	local night_mode_enabled = glb_night_mode_enabled
	local night_mode_start_time = glb_night_mode_start_time
	local night_mode_end_time = glb_night_mode_end_time
	local night_mode_on_seconds = glb_night_mode_on_seconds
	local night_mode_off_seconds = glb_night_mode_off_seconds
	local daily_on_mode_start_time = glb_daily_on_mode_start_time
	local daily_on_mode_end_time = glb_daily_on_mode_end_time
	local system_off_enabled = glb_system_off_enabled 
	local system_off_start_minute = glb_system_off_start_minute
	local system_off_end_minute = glb_system_off_end_minute
	local system_off_update_interval_minutes = glb_system_off_update_interval_minutes

	if (ReadSavedGroupSettings()) then
		-- file exists - check for changes
		if ((night_mode_enabled ~= glb_night_mode_enabled) or 
		    (night_mode_start_time ~= glb_night_mode_start_time) or 
		    (night_mode_end_time ~= glb_night_mode_end_time) or 
		    (night_mode_on_seconds ~= glb_night_mode_on_seconds) or 
		    (night_mode_off_seconds ~= glb_night_mode_off_seconds) or 
		    (daily_on_mode_start_time ~= glb_daily_on_mode_start_time) or 
		    (daily_on_mode_end_time ~= glb_daily_on_mode_end_time) or 
		    (system_off_enabled ~= glb_system_off_enabled) or 
		    (system_off_start_minute ~= glb_system_off_start_minute) or 
			(system_off_end_minute ~= glb_system_off_end_minute) or
			(system_off_update_interval_minutes ~= glb_system_off_update_interval_minutes)) then
			need_to_save = true
			-- restore the new vaulues
			glb_night_mode_enabled = night_mode_enabled
			glb_night_mode_start_time = night_mode_start_time
			glb_night_mode_end_time = night_mode_end_time
			glb_night_mode_on_seconds = night_mode_on_seconds
			glb_night_mode_off_seconds = night_mode_off_seconds
			glb_daily_on_mode_start_time = daily_on_mode_start_time
			glb_daily_on_mode_end_time = daily_on_mode_end_time
			glb_system_off_enabled = system_off_enabled 
			glb_system_off_start_minute = system_off_start_minute
			glb_system_off_end_minute = system_off_end_minute
			glb_system_off_update_interval_minutes = system_off_update_interval_minutes
		end
	else
		-- no file
		need_to_save = true
	end 

	if need_to_save then
		local status, fp = pcall(io.open, GROUP_SETTINGS_FILE, 'w')
		local night_mode_enabled_i = 0
		if night_mode_enabled then night_mode_enabled_i = 1 end
		local system_off_enabled_i = 0
		if system_off_enabled then system_off_enabled_i = 1 end
		if status then
			local current_group_settings_str = string.format([[%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s]],
			tostring(night_mode_enabled_i),
			tostring(night_mode_start_time),
			tostring(night_mode_end_time),
			tostring(night_mode_on_seconds),
			tostring(night_mode_off_seconds),
			tostring(daily_on_mode_start_time),
			tostring(daily_on_mode_end_time),
			tostring(system_off_enabled_i),
			tostring(system_off_start_minute),
			tostring(system_off_end_minute),
			tostring(system_off_update_interval_minutes))
			fp:write(current_group_settings_str,"\n")
			fp:close()
			printToSOSlog ("Saved group settings "..current_group_settings_str.." sccessfully") -- TODO debug remove
		else
			printToSOSlog ("Failed to save to "..GROUP_SETTINGS_FILE.."!!") -- TODO debug remove
		end
	end
end

-- ------------------------------------------------------------------
-- Read group settings from local file
function ReadSavedGroupSettings()

	if not file_exists(GROUP_SETTINGS_FILE) then return false end
	
	for line in io.lines(GROUP_SETTINGS_FILE) do 
		arr_size, str_arr = split(line, ";")
		local idx = 1;
		if arr_size > (idx - 1) then
			if tonumber(str_arr[idx]) == 1 then glb_night_mode_enabled = true else glb_night_mode_enabled = false end
		end
		idx = idx + 1
		if arr_size > (idx - 1) then
			glb_night_mode_start_time = tonumber(str_arr[idx])
		end
		idx = idx + 1
		if arr_size > (idx - 1) then
			glb_night_mode_end_time = tonumber(str_arr[idx])
		end
		idx = idx + 1
		if arr_size > (idx - 1) then
			glb_night_mode_on_seconds = tonumber(str_arr[idx])
		end
		idx = idx + 1
		if arr_size > (idx - 1) then
			glb_night_mode_off_seconds = tonumber(str_arr[idx])
		end
		idx = idx + 1
		if arr_size > (idx - 1) then
			glb_daily_on_mode_start_time = tonumber(str_arr[idx])
		end
		idx = idx + 1
		if arr_size > (idx - 1) then
			glb_daily_on_mode_end_time = tonumber(str_arr[idx])
		end
		idx = idx + 1
		if arr_size > (idx - 1) then
			if tonumber(str_arr[idx]) == 1 then glb_system_off_enabled = true else glb_system_off_enabled = false end
		end
		idx = idx + 1
		if arr_size > (idx - 1) then
			glb_system_off_start_minute = tonumber(str_arr[idx])
		end
		idx = idx + 1
		if arr_size > (idx - 1) then
			system_off_end_minute = tonumber(str_arr[idx])
		end
		idx = idx + 1
		if arr_size > (idx - 1) then
			system_off_update_interval_minutes = tonumber(str_arr[idx])
		end
		return true
	end
  end
-- ------------------------------------------------------------------
-- --------------- Cloud Database functions -------------------------
-- ------------------------------------------------------------------

-- send status report, check changes in global paramters and check for updates
-- paramter: isPowerUp - true if first call after power up
function ReportStatusGetUpdates(isPowerUp, isShutDown)
    local oper = "status"
    if isPowerUp then
        oper = "powerup"
    end
		if isShutDown then
			oper = "shutdown"
		end

    local wifi_up_time = glb_total_wifi_seconds + os.time() - glb_wifi_on_start_time
    if glb_wifi_on_start_time == 0 then
        wifi_up_time = glb_total_wifi_seconds
    end
    
    local _rx_val, _tx_val, _rate_val = GetDataCounters()
    local current_values_str = string.format([['%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s']],
        os.date("%Y-%m-%d %X"), glb_mac_address, GetVoltmeter(), GetAmperemeter(), tostring(os.difftime(os.time(),glb_powerup_time)), 
        tostring(wifi_up_time), 0, 0, tostring(_rx_val), tostring(_tx_val), tostring(_rate_val),oper)
        
    printToSOSlog("ReportStatusGetUpdates - current values str="..current_values_str)   -- TODO debug remove

    if WaitForInternetConnection() then
        printToSOSlog("ReportStatusGetUpdates - internet connection OK")   -- TODO debug remove
        -- create environment object
        local env = assert (luasql_driver.mysql())
        -- connect to data source
        local con,errorString = env:connect(luasql_dbname,luasql_user,luasql_password,luasql_host,luasql_port)
        if con then
            printToSOSlog("ReportStatusGetUpdates - Connected to database OK")   -- TODO debug remove

            -- send save records from file to cloud
            local stored_records = ReadStoredRecords()
            for idx,record in pairs(stored_records) do
                printToSOSlog("ReportStatusGetUpdates - found stats record: ''"..record.."'")   -- TODO debug remove
                local query = string.format([[
                    INSERT INTO nodes_stats (time_created, node_id, millivolt, uptime_seconds, wifi_uptime_seconds, 
                    max_period_connections, cellular_uptime_seconds, operation) 
                    VALUES (%s)]], record)
                status,errorString = con:execute(query)
                if status then
                    printToSOSlog("Send stored stats record to DB OK")   -- TODO debug remove
                else
                    printToSOSlog("query: "..query) -- TODO debug remove
                    printToSOSlog("Failed!!") -- TODO debug remove
                    printToSOSlog (errorString) -- TODO debug remove
                end
            end
            -- remove the stored records file
            local del_ok, del_err = os.remove (STORED_RECORDS_FILE)
            if del_ok then
                printToSOSlog(STORED_RECORDS_FILE.."removed  OK")   -- TODO debug remove
            else
                printToSOSlog("failed to remove "..STORED_RECORDS_FILE..": error="..del_err)   -- TODO debug remove
            end


            -- send the current values to cloud
            local query = string.format([[
			INSERT INTO nodes_stats (time_created, node_id, millivolt, milliamp, uptime_seconds, wifi_uptime_seconds, 
			max_period_connections, cellular_uptime_seconds, daily_kbytes_tx, daily_kbytes_rx, daily_avg_kbitrate, operation) 
                VALUES (%s)]],current_values_str)
            status,errorString = con:execute(query)
            if status then
                printToSOSlog("Sent current stats to DB OK")   -- TODO debug remove
            else
                printToSOSlog("query: "..query) -- TODO debug remove
                printToSOSlog("Failed!!") -- TODO debug remove
                printToSOSlog (errorString) -- TODO debug remove
            end
            
		if isShutDown then
			con:close()
			return
		end

            -- check parameters
            local group_id = ""
			local script_file = ""
			local ip_lan = ""
            for groupid, scriptfile, iplan in rows (con, "select groupid, scriptfile, iplan from devices where iddevices='"..glb_mac_address.."'") do
				if groupid ~= nil then
					group_id = groupid
				end
				if scriptfile ~= nil then
					script_file = scriptfile
				end
				if iplan ~= nil then
					ip_lan = iplan
				end
                printToSOSlog (string.format ("%s: %s", groupid, scriptfile)) -- TODO debug remove
                break
			end
			-- if found, check if need to update software and/or gateway IP address
			if group_id ~= "" then
				-- if successfully read assigned IP - check if need to update it
				if FillGWIPAddress() then
					if (ip_lan ~= glb_gw_ip) and (glb_gw_ip ~= "") then
						printToSOSlog ("IP address changed from "..ip_lan.." to "..glb_gw_ip.." - updating table on server") -- TODO debug remove
						local query = string.format([[UPDATE devices SET iplan='%s' WHERE (iddevices='%s')]],glb_gw_ip, glb_mac_address)
						status,errorString = con:execute(query)
						if status then
							printToSOSlog("Updated IP address to DB OK")   -- TODO debug remove
						else
							printToSOSlog("query: "..query) -- TODO debug remove
							printToSOSlog("Failed!!") -- TODO debug remove
							printToSOSlog (errorString) -- TODO debug remove
						end
					end
				end
                printToSOSlog("Found group "..group_id.." info OK")   -- TODO debug remove
                if (script_file ~= glb_script_file_name) then
                    printToSOSlog ("Updating script from "..glb_script_file_name.." to "..script_file) -- TODO debug remove
                    local file_name = ""
                    -- need to update scrip file 
                    for filename, description, filedata in rows (con, "select * from scriptfiles WHERE (filename='"..script_file.."')") do
                        printToSOSlog ("Found entry for "..script_file) -- TODO debug remove
                        file_name = filename
                        local status, fp = pcall(io.open,"/tmp/"..filename..".gz", "w")
                        if status and filedata  then
                            fp:write(filedata)
                            fp:close()
                            printToSOSlog ("Downloaded "..script_file.." sccessfully") -- TODO debug remove
                        else
                            printToSOSlog ("Failed to download "..script_file.."!!") -- TODO debug remove
                        end
                        break
                    end
                    if (file_exists("/tmp/"..file_name..".gz")) then
                        printToSOSlog("extracting "..file_name..".gz")
                        -- extract and force overwrite - if exists
                        os.execute("gzip -df /tmp/"..file_name..".gz")
                        if IsValidScriptFile("/tmp/"..file_name) then
                            -- copy the file to the flash
                            os.execute("cp /tmp/"..file_name.." /usr/soswifi")
                            -- save the name in the script name file
                            SaveScriptNameToFile(file_name)
                            -- update the "last update time" in the devices table to now
                            res = assert (con:execute(string.format([[UPDATE devices SET updatedate='%s' WHERE (iddevices='%s')]],
                                    os.date("%Y-%m-%d %X"), glb_mac_address)))

                            -- going to reboot - close connection
                            con:close()
                            env:close()
                            -- reboot
                            sleep(5)
						os.execute("reboot")
                            sleep(5)
                            printToSOSlog("no REBOOT... restart script") -- TODO debug remove
                            -- in case the reboot didn't catch
                            os.exit()
                            end
                    end
                end
                -- get group paramters and upate globals accordingly
			for idgroups, groupname, nightmodeenabled, nightmodestart, nightmodeend, nightmodeonsecs, nightmodeoffsecs, webonstart, webonend, systemoffenabled, systemoffstartminute, systemofflengthminutes, systemoffendminute, cellularondemand, systemoffupdateintervalminutes
						in rows (con, "select * from groups where idgroups='"..group_id.."'") do
				printToSOSlog (string.format ("Found groups entry %s: %s %s %s %s %s %s %s %s %s %s %s %s %s %s", idgroups, groupname, nightmodeenabled, nightmodestart, nightmodeend, nightmodeonsecs, nightmodeoffsecs, webonstart, webonend, systemoffenabled, systemoffstartminute, systemofflengthminutes, systemoffendminute, cellularondemand, systemoffupdateintervalminutes)) -- TODO debug remove
					glb_night_mode_enabled = false
					if (nightmodeenabled == '1') then 
						glb_night_mode_enabled = true 
					else
						glb_night_mode_enabled = false
					end
					glb_night_mode_start_time = tonumber(nightmodestart)
					glb_night_mode_end_time = tonumber(nightmodeend)
					glb_night_mode_on_seconds = tonumber(nightmodeonsecs)
					glb_night_mode_off_seconds = tonumber(nightmodeoffsecs)
					glb_daily_on_mode_start_time = tonumber(webonstart)
					glb_daily_on_mode_end_time = tonumber(webonend)	
					if (systemoffenabled == '1') then 
						glb_system_off_enabled = true 
					else
						glb_system_off_enabled = false
					end
					glb_system_off_start_minute = tonumber(systemoffstartminute)
				-- glb_system_off_length_minutes = tonumber(systemofflengthminutes)
					glb_system_off_end_minute = tonumber(systemoffendminute)
					glb_system_off_update_interval_minutes = tonumber(systemoffupdateintervalminutes)
					SaveGroupSettingsToFile()
					break
                end
            end		
            con:close()
            -- reset values to next report
            glb_total_wifi_seconds = 0
            glb_last_status_update = os.time()
        else
            printToSOSlog ("ReportStatusGetUpdates - Failed to connect to database:") -- TODO debug remove
            printToSOSlog(errorString)
        end
        env:close()
	else -- no internet connection
		-- save record to file
		AddRecordToLocalFile(current_values_str)
		-- read last saved group settings
		ReadSavedGroupSettings()
    end
end

-- generic rows reader
function rows (connection, sql_statement)
	local cursor,errorString = connection:execute (sql_statement)
	if cursor then
		return function ()
			return cursor:fetch()
		end
	end
end


--  -------------- fill gateway's br-lan IP address -----------------------------------
function FillGWIPAddress()
	local f = io.popen("ifconfig br-lan | grep 'inet addr'") -- runs command
	local ipaddr = f:read("*a") -- read output of command "inet addr:192.168.1.162  Bcast:192.168.1.255  Mask:255.255.255.0"
	local strt, dd = string.find(ipaddr, 'inet addr') -- find the IP address start position 
	if not strt then
		print("Failed to find br-lan IP address")
		return false
	end
	local ipend, dd = string.find(ipaddr, 'Bcast') -- find the "Bcast" position  (end of the IP)
	glb_gw_ip = string.sub(ipaddr, strt + 10, ipend - 1) -- get the IP between 
	glb_gw_ip = string.gsub(glb_gw_ip, ' ', '') -- remove extra spaces
	f:close()
	return true
end


-- ------------------------------------------------------------------
-- ------------------------------------------------------------------

--  -------------- check if time to send status/check for updates -------------------------
function StatusOrUpdateTimeout() 
    local now = os.time()
	if (os.difftime(now, glb_last_status_update) >= SEND_STATUS_CHECK_UPDATE_INTERVAL_SECS) then return true end
	return false
end

--  -------------- check if in daily on period (between start/stop) ----------------------
function IsDailyON() 
    local now = os.date("*t")
	local now_secs = (now.hour * 3600) + (now.min * 60) + now.sec
	local ret_val = false
	if (glb_daily_on_mode_start_time > glb_daily_on_mode_end_time) then 
		if ((now_secs >= glb_daily_on_mode_end_time) and (now_secs <= glb_daily_on_mode_start_time)) then
			ret_val = true
		end
	else
		if ((now_secs >= glb_daily_on_mode_start_time) and (now_secs <= glb_daily_on_mode_end_time)) then
			ret_val = true
		end
	end
	return ret_val
end

--  -------------- check if in night mode (between start/stop) ----------------------
function IsInNightMode() 
    local now = os.date("*t")
	local now_secs = (now.hour * 3600) + (now.min * 60) + now.sec
	local ret_val = false
	if ((now_secs >= glb_night_mode_start_time) or (now_secs <= glb_night_mode_end_time)) then
		ret_val = true
	end
	return ret_val
end

--  -------------- check if during nigth mode on period ----------------------
function IsNightModeONTime() 
	if glb_night_mode_enabled then -- JIC - we shouldn't get here if nightmode is not enabled 
		local now = os.date("*t")
		local now_secs = (now.min * 60) + now.sec
		local cycle = glb_night_mode_on_seconds + glb_night_mode_off_seconds
		local cycle_start = math.floor(now_secs / cycle) * cycle
		local ret_val = false
		printToSOSlog("(now_secs "..tostring(now_secs).." - cycle_start"..tostring(cycle_start)..") <= glb_night_mode_on_seconds "..tostring(glb_night_mode_on_seconds))
		if ((now_secs - cycle_start) <= glb_night_mode_on_seconds) then
			ret_val = true
		end
		return ret_val
	else
		return true 
	end
end

--  -------------- check if need to turn off system  ----------------------
--  Need to shut down if "now" is in A or in B
--  midnight      sunrise               sunset    midnight  
-- Option I:      (end)                (start)
--     |------------+---------------------+---------|
--     |<----A----->|                     |<---B--->|
--                                    
-- Option II     (start)                (end)
--     |------------+---------------------+---------|
--     |            |<--------C---------->|         |
--                                    
function CheckSystemOFF() 
	if glb_system_off_enabled then 
		local now = os.date("*t")
		local now_min = (now.hour * 60) + now.min		
		local power_off = false
		if (((glb_system_off_start_minute > glb_system_off_end_minute) and ((now_min >= glb_system_off_start_minute) or (now_min < glb_system_off_end_minute))) or      -- option I
			((glb_system_off_start_minute < glb_system_off_end_minute) and ((now_min >= glb_system_off_start_minute) and (now_min < glb_system_off_end_minute)))) then  -- option II
			power_off = true
		end
		if (power_off) then
			local off_minutes = glb_system_off_update_interval_minutes
			if (now_min < glb_system_off_end_minute) then -- Option I, range A  or Option II, range C 
				if ((glb_system_off_end_minute - now_min) < glb_system_off_update_interval_minutes) then
					off_minutes = glb_system_off_end_minute - now_min
				end
			else -- now > start ==> only in Option I, range B 
				if ((TOTAL_MINUTES_PER_DAY - now_min + glb_system_off_end_minute) < glb_system_off_update_interval_minutes) then
					off_minutes = glb_system_off_end_minute - TOTAL_MINUTES_PER_DAY - now_min + glb_system_off_end_minute
				end
			end
			printToSOSlog("Power system off: now_min="..tostring(now_min).." start min="..tostring(glb_system_off_start_minute).." end min="..tostring(glb_system_off_end_minute).." off minutes="..tostring(off_minutes))
			ReportStatusGetUpdates(false,true)
			-- os.execute("echo \"1\" > /sys/class/gpio/gpio"..SYSTEM_POWER_CONTROL_GPIO.."/value");
			-- fill command in first 4 bits and shift the total minutes by 4 (multiply by 16) and 
			SendDataToMainPowerSwitch(GPIO_SLEEP_COMMAND  + (off_minutes * GPIO_PARAMETER_SHIFTER)) 

            -- ====================================================================================================
			-- this code if for verification - at this point the main power should be off so it does not run
			-- however... if power is still on, it might be that the power switch is in wrong state
			-- sleep for 5 minutes = this will ensure the power switch resets its state machine and ready for next command
			sleep(300) 
			-- sends retry in case the previous didn't catch
			SendDataToMainPowerSwitch(GPIO_SLEEP_COMMAND  + (off_minutes * GPIO_PARAMETER_SHIFTER)) 
			printToSOSlog("Power off error!!: (if this msg is shown without simulation - the power switch is not working!)");
			DoMaintenance("yossics@gmail.com", true,"SIMULATION of power off")
			sleep(off_minutes*60)
			printToSOSlog("REBOOT") -- TODO debug remove
			os.execute("reboot")
			sleep(5)
			printToSOSlog("no REBOOT... restart script") -- TODO debug remove
			-- in case the reboot didn't catch
			os.exit()
            -- ====================================================================================================

		end
	end
end

--  -------------- sleep seconds (non blocking) -----------------------------------
function sleep(n)
  os.execute("sleep " .. tonumber(n))
end

--  -------------- check if file exists -----------------------------------
function file_exists(name)
	local status, fp = pcall(io.open,name,"r")
   if (status and (fp ~= nil)) then io.close(fp) return true else return false end
end

--  -------------- check if file is a valid lua script and if it exist -----------------------------------
function IsValidScriptFile(filename)
	-- local status, fp = pcall(io.open,filename,"rb")
	-- if (status and (fp ~= nil)) then 
	-- 	local line = fp:read(15) 
	-- 	io.close(fp) 
	-- 	-- cover either lua or luac files
    --     if (string.sub(line,1,14) == "#!/usr/bin/lua") or (string.sub(line,2,4) == "uaQ") then
    --         printToSOSlog(filename.." is a valid script file")   -- TODO debug remove
	-- 		return true
	-- 	end
    --     printToSOSlog("ERROR: "..filename.." is an invalid script file!")   -- TODO debug remove
	-- 	return false
	-- else
    --     printToSOSlog("ERROR: could not validate "..filename.." !")   -- TODO debug remove
	-- 	return false
	-- end
	return true
end

--  -------------- fill global mac address -----------------------------------
function FillMACAddress()
	local f = io.popen("ifconfig | grep wlan0-1") -- runs command
	local macstr = f:read("*a") -- read output of command "wireless.radio0.macaddr=c4:93:00:0e:79:f0"
	local strt,dd=string.find(macstr, 'HWaddr') -- find the "HWaddr" position 
	glb_mac_address = string.upper(string.gsub(string.sub(macstr, strt + 7), ':', '')) -- get only the MAC and remove the ':'
	glb_mac_address = string.gsub(glb_mac_address, '\n', '') -- remove the '\'
	glb_mac_address = string.gsub(glb_mac_address, ' ', '') -- remove extra spaces
	f:close()
end

--  -------------- fill global script name -----------------------------------
function FillScriptNameGlobal()
	local f=io.open(SCRIPT_NAME_FILE,"r")
	if f~=nil then 
		for line in f:lines () do
			glb_script_file_name = line
			break
		end 
		io.close(f) 
	end
end

--  -------------- update script name file -----------------------------------
function SaveScriptNameToFile(scriptName)
	local f=io.open(SCRIPT_NAME_FILE,"w")
	if f~=nil then 
		f:write(scriptName.."\n")
		io.close(f) 
	end
end

--  -----------------------------------------------------
-- -------------- main -----------------------------------
--  -----------------------------------------------------

-- initializations
-- delay (~1 minute) between boot and start running - to allow network to stablize
sleep(90)
printToSOSlog("=========== SOSwifi Gateway ver: "..VERSION_NAME.." ==============")
initialize()
printToSOSlog("Script running: "..glb_script_file_name)
PowerWiFi(true)
sleep(2)
glb_powerup_time = os.time() - 92 
-- same for wifi uptime
glb_wifi_on_start_time = os.time()
printToSOSlog("Connected to the internet")
ReportStatusGetUpdates(true,false)
local current_state = 1
-- main state machine loop
while true do

	-- TODO remove debug condition to stop script
	if (file_exists("/usr/soswifi/stop_lua")) then
		printToSOSlog("stop_lua found - exit script")
		break
	end

	-- printToSOSlog("state="..tostring(current_state)) -- TODO debug remove

	-- send keep alive to main switch - if needed
	if glb_IS_KEEP_ALIVE_ENABLED then
		SendKeepAliveToMainSwitch() 
	end

	-- ---------------------------------------------------
    if (current_state == 1) then
        if  StatusOrUpdateTimeout() then
            current_state = 2
        else
            current_state = 3
        end
	-- ---------------------------------------------------
	elseif (current_state == 2) then
        ReportStatusGetUpdates(false, false) -- on the gateway this function will store data for later if there is no internet connection (and read last saved settings from local file)
		current_state = 3
	-- ---------------------------------------------------
	elseif (current_state == 3) then
		-- Check system off
		CheckSystemOFF()
		-- main Loop delay
		sleep(CHECK_NETWORK_CONNECTION_POLLING_TIME)
		if IsInNightMode() then
			current_state = 4
		else
			current_state = 1
		end
	-- ---------------------------------------------------
	elseif (current_state == 4) then
		if IsNightModeONTime() then
			PowerWiFi(true)
			current_state = 1
		else
			current_state = 5
		end
	-- ---------------------------------------------------
	elseif (current_state == 5) then
        if WaitForInternetConnection() then
			current_state = 1 -- connected
		else
			current_state = 6
		end
	-- ---------------------------------------------------
	elseif (current_state == 6) then
		if not IsDailyON() then
			PowerWiFi(false)
		end
        current_state = 1
    -- ---------------------------------------------------
	end
end -- do while - main state machine loop


printToSOSlog("script is not running anymore")
