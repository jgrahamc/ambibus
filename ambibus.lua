-- Ambient Bus Arrival Monitor
--
-- Small program designed to run on a hacked Linksys WRT54GL (but could
-- run on any box that has a suitably connected serial LED display) with
-- a SparkFun Serial LED display connected to the serial port.
--
-- This program retrieves bus arrival time from Transport for London for
-- specific bus routes and a single bus stop and displays up to two
-- arrival times on the display for the buses arriving next.
--
-- Copyright (c) 2012-2016 John Graham-Cumming
--
-- See file LICENSE for license information

JSON = assert(loadfile "JSON.lua")()

-- These must be set to the AppId and AppKey from the TfL web site
-- https://api.tfl.gov.uk/ (register to obtain them)

local APP_ID = ""
local APP_KEY = ""

-- display_send: write a string of characters directly to the display via
-- the serial port
function display_send(d)
    if debug then
       print(d)
       return
    end

    local out = io.open(serial, "wb")

    if ( out ~= nil ) then
        out:write(d)
        out:close()
    end
end

-- display_brightness: set the brightness of the LED
function display_brightness(b)
   display_send(string.format("\122%c", b))
end

-- display_colon: enable or disable the : in the middle of the display
function display_colon(on)
   if ( on == 1 ) then
      display_send("\119\016")
   else
      display_send("\119\000")
   end
end

-- display_quad: send 4 characters to the display starting with the left
-- most digit.
function display_quad(q)
    if ( #q ~= 4 ) then
        fail("display_quad called with wrong length string")
    end

    if debug then
        print("display_quad: " .. q)
    end

    -- The following is a bit of a hack but it improves readability
    -- of the display.  If we want to display x123 it's better to display
    -- 1x23.  If the second number has two digits and the first number has
    -- one then flip the first two to leave a space between.

    if ( ( q:sub(3,3) ~= " " ) and ( q:sub(1,1) == " " ) ) then
       tq = q:sub(2,2) .. " " .. q:sub(3,4)
       q = tq
    end

    display_send("\118")

    -- Because the display is mounted upside down in the bus it is
    -- necessary to alter the characters that are sent and sent them
    -- in the reverse order
    --
    -- Unfortunately there isn't a useful character to map 1 to so
    -- it is mapped to a blank here and then we keep track of the
    -- positions that need a 1 and manually set the correct LEDs

    local ones = {}

    local xlat = { ["0"] = "0", ["1"] = "x", ["2"] = "2", ["3"] = "E", ["4"] = "h",
                   ["5"] = "5", ["6"] = "9", ["7"] = "L", ["8"] = "8", ["9"] = "6" }

    local nq = ""

    for i = 1, #q do
       local c = q:sub(i,i)
       local x = xlat[c]
       if ( x ~= nil ) then
          nq = x .. nq
          if ( x == "x" ) then
              table.insert(ones, i)
          end
       else
          nq = c .. nq
       end
    end

    display_send(nq)

    for i, o in pairs(ones) do
       display_send(string.format("%c\048", 0x7A + (5-o)))
    end
end

-- display_line: show a line in the middle of the display on all four
-- digits
function display_line()
    display_quad("----")
end

-- display_blank: clear the display completely
function display_blank()
    display_send("\118xxxx")
end

-- split: break a string into a table of words separated by commas
function split(s)
    local words = {}
    for word in s:gmatch("[^,]+") do
        table.insert(words, word)
    end

    return words
end

-- fail: a fatal error has occurred.  Output a message and terminate
-- the program
function fail(m)
    print(m)
    os.exit(1)
end

-- usage: terminate the program showing usage information
function usage()
    fail("Usage: ambibus.lua <routes> <stop> <walktime>")
end

-- retrieve_buses: get the latest bus times from the TfL API and fill
-- in the times table
function retrieve_buses()
   local url = string.format("https://api.tfl.gov.uk/StopPoint/%s/arrivals?app_id=%s&app_key=%s", stop, APP_ID, APP_KEY)
   local wget = string.format("wget -O - -q '%s'", url)
   if debug then
      print(wget)
   end

   local c = io.popen(wget, "r")
   local json = c:read("*a")
   c:close()

   if debug then
      print(json)
   end

   local temp = {}

   local buses = JSON:decode(json)

   for i, bus in ipairs(buses) do
      local lineName = bus["lineName"]
      for i, l in pairs(routes) do
         if ( l == lineName ) then
            local tts = bus["timeToStation"]
            local minutes = math.floor(tts / 60)
            minutes = minutes - walk

            if ( minutes >= 0 ) then
               table.insert(temp, minutes)
               if debug then
                  print(lineName, " in ", minutes)
               end
            end

            break
         end
      end
   end

   -- Ensure that the retrieved times are in ascending order as the JSON can't
   -- be guaranteed to have the correct ordering

   table.sort(temp)

   return temp
end

-- update_display: show the two earliest buses on the display.  This will
-- take into account the time elapsed since the last_retrieve so that

function update_display(t)
   delta = math.floor((os.time() - last_retrieve) / 60)

   local temp = {}
   for i, b in pairs(t) do
      if ( (b - delta) >= 0 ) then
         table.insert(temp, b-delta)
      end
   end

   if ( #temp == 0 ) then
      display_blank()
   else
      quad = "xxxx"
      if ( #temp == 1 ) then
         quad = string.format("xx%2d", temp[1])
      else
         quad = string.format("%2d%2d", temp[1], temp[2])
      end

      display_quad(quad)
   end
end

-- The first argument on the command-line should be a list of bus routes
-- to be examined separated by commas.  e.g. 11 or 11,411

if ( arg[1] == nil ) then
   usage()
end
routes = split(arg[1])

-- The second argument is the bus stop number which must be obtained from
-- TfL. The easiest way to do this is to find the appropriate bus stop
-- on the TfL web site and copy/paste the ID from the URI. For example,
-- https://tfl.gov.uk/bus/stop/490007865E/westminster-registration-office/
-- is a bus stop and the ID is 490007865E.

if ( arg[2] == nil ) then
   usage()
end
stop = arg[2]

-- The third argument is the 'walking time' which is subtracted from bus
-- times to allow the person using the monitor to walk to the bus stop.
-- Set to zero for actual times.

if ( arg[3] == nil ) then
   usage()
end
walk = tonumber(arg[3])

-- Optional fourth argument causes output to console instead of serial port

debug = ( arg[4] ~= nil)

-- This determines the update time (in seconds) of the display.  The display
-- will be updated every time that interval has expired.

update = 30

-- This determines how often to ask the TfL API for new information.
-- If this is greater than update then the program will interpolate
-- between the times it did an update.  The second variable is used to
-- update more frequently if no bus times have been found.  This is
-- can be helpful when no buses come for a while.  This must not be
-- less than 10 seconds as the TfL API used cannot be called more than
-- once every 10 seconds.

retrieve = 30
retrieve_no_info = 10

-- This is the serial device that the LED display is connected to, we
-- force it to 9600 baud 8n1 here using the stty program (which must be
-- available on the PATH)
--
-- -parenb disable the parity bit
-- -cstopb sets 1 stop bit
-- ospeed sets the output baud rate

if not debug then
   serial = "/dev/ttyS1"
   rc = os.execute(string.format("stty -F %s ospeed 9600 -parenb cs8 -cstopb", serial))
   if ( rc ~= 0 ) then
      fail("Can't run STTY to set up serial port")
   end
end

-- These two variables store the time of the last update of the display and
-- last retrieval of data from the API.  They are initially set to zero
-- so that a retrieve and update will occur the first time through

last_update = 0
last_retrieve = 0

-- These two variables contain the period of time for which the display
-- is enabled and the API accessed.  Both are an hour/minute in 24h
-- format

start = 0700
finish = 2000

-- Used to determine whether we have valid bus data and store the
-- data itself

valid = 0
times = {}

display_brightness(1)
display_blank()
display_line()

while (1) do

   -- Retrieve the current time in hours/minutes and see if we are
   -- inside the update window specified by start and finish.  If not
   -- then shut off the display

   sleep_for = "5s"

   current = tonumber(os.date("%H%M"))

   if ( ( current >= start ) and ( current <= finish ) ) then
      now = os.time()

      if ( now >= ( last_retrieve + retrieve ) or
       ( ( #times == 0 ) and
         ( now >= ( last_retrieve + retrieve_no_info ) ) ) ) then
         times = retrieve_buses()
         last_retrieve = now
      end

      if ( now >= ( last_update + update ) ) then
         update_display(times)
         last_update = now
      end
   else
      sleep_for = "5m"

      display_blank()
   end

   -- Wait before checking again.  The wait time depends on whether
   -- the system is active or sleeping (out of hours)

   os.execute("sleep " .. sleep_for)
end
