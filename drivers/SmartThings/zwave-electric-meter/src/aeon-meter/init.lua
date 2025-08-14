-- Copyright 2022 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version=1 })
local capabilities = require "st.capabilities"
local Meter = (require "st.zwave.CommandClass.Meter")({ version=3 })
local cc = require "st.zwave.CommandClass"
local Association = (require "st.zwave.CommandClass.Association")({ version=2 })
local utils = require "st.utils"

local AEON_FINGERPRINTS = {
  {mfr = 0x0086, prod = 0x0002, model = 0x0009},  -- DSB09xxx-ZWUS
  {mfr = 0x0086, prod = 0x0002, model = 0x0001},  -- DSB28-ZWEU
}

local function can_handle_aeon_meter(opts, driver, device, ...)
  for _, fingerprint in ipairs(AEON_FINGERPRINTS) do
    if device:id_match(fingerprint.mfr, fingerprint.prod, fingerprint.model) then
      return true
    end
  end
  return false
end

-- Function to handle Association reports to verify automatic reporting is set up
local function association_report_handler(self, device, cmd)
  print(string.format("ASSOCIATION REPORT: Group %d has %d nodes",
                    cmd.args.grouping_identifier,
                    #cmd.args.node_ids))

  -- Print each node ID in the group
  if #cmd.args.node_ids > 0 then
    local nodes_str = ""
    for i, node_id in ipairs(cmd.args.node_ids) do
      nodes_str = nodes_str .. string.format("0x%02X ", node_id)
    end
    print(string.format("  Node IDs: %s", nodes_str))
  else
    print("  No nodes in this group - automatic reporting won't work!")
  end
end

-- Function to set up associations for automatic reporting
local function setup_automatic_reporting(device)
  print("====== SETTING UP AUTOMATIC REPORTING ======")

  -- The Aeon HEM uses association groups for automatic reporting
  -- Group 1: Lifeline (controller) - essential for automatic reporting
  -- Group 2: Reports for Endpoint 1 (First Clamp)
  -- Group 3: Reports for Endpoint 2 (Second Clamp)
  -- Group 4: Reports for Endpoint 3 (Battery)

  -- Try different node IDs to ensure the hub receives reports
  -- Some Z-Wave networks might have hub at node 1, others at different IDs
  local node_ids = {0x01, 0x02, 0xFF}  -- Try node 1, node 2, and broadcast address (0xFF)

  print("Configuring association groups to enable automatic reporting...")

  -- Try setting multiple node IDs in each group for better reliability
  print("Setting association group 1 (Lifeline)...")
  device:send(Association:Set({grouping_identifier = 1, node_ids = node_ids}))  -- Lifeline group

  print("Setting association group 2 (First clamp)...")
  device:send(Association:Set({grouping_identifier = 2, node_ids = node_ids}))  -- First clamp group

  print("Setting association group 3 (Second clamp)...")
  device:send(Association:Set({grouping_identifier = 3, node_ids = node_ids}))  -- Second clamp group

  print("Setting association group 4 (Battery)...")
  device:send(Association:Set({grouping_identifier = 4, node_ids = node_ids}))  -- Battery group

  -- Verify the associations were set correctly
  device.thread:call_with_delay(2, function()
    print("Verifying association group configuration...")
    device:send(Association:Get({grouping_identifier = 1}))
    device:send(Association:Get({grouping_identifier = 2}))
    device:send(Association:Get({grouping_identifier = 3}))
    device:send(Association:Get({grouping_identifier = 4}))
  end)

  print("============================================")
end

local do_configure = function (self, device)
  print("====== CONFIGURING: Aeon Home Energy Meter ======")

  -- REVISED UNDERSTANDING:
  -- Aeon HEM Configuration is based on report groups, not directly on endpoints
  -- Group 1 (parameter 101): First Clamp readings
  -- Group 2 (parameter 102): Second Clamp readings
  -- Group 3 (parameter 103): Battery reporting
  -- The root device (EP0) reports the total combined reading automatically

  -- NOTE: For these values, the bits represent:
  -- Bit 0 (0x01): kWh of Clamp 1
  -- Bit 1 (0x02): W of Clamp 1
  -- Bit 2 (0x04): kWh of Clamp 2
  -- Bit 3 (0x08): W of Clamp 2
  -- Bit 4 (0x10): kWh of Clamp 3/Battery?
  -- Bit 5 (0x20): W of Clamp 3/Battery?
  -- Bit 6 (0x40): Reserved
  -- Bit 7 (0x80): Reserved

  -- Values:
  -- 0x03 (0b00000011) = W+kWh of Clamp 1
  -- 0x0C (0b00001100) = W+kWh of Clamp 2
  -- 0x30 (0b00110000) = W+kWh of Clamp 3/Battery

  print("Sending configuration parameters to enable all reporting groups...")

  -- Configure for 2 physical clamps plus battery
  local group1_value = 3     -- Enable W+kWh for First clamp (0x03)
  local group2_value = 12    -- Enable W+kWh for Second clamp (0x0C)
  local group3_value = 48    -- Enable battery reporting (0x30)

  -- Send configuration commands with more information
  print(string.format("Setting parameter 101 (Group 1/First Clamp) to %d (0x%02X)", group1_value, group1_value))
  device:send(Configuration:Set({parameter_number = 101, size = 4, configuration_value = group1_value}))

  print(string.format("Setting parameter 102 (Group 2/Second Clamp) to %d (0x%02X)", group2_value, group2_value))
  device:send(Configuration:Set({parameter_number = 102, size = 4, configuration_value = group2_value}))

  print(string.format("Setting parameter 103 (Group 3/Battery) to %d (0x%02X)", group3_value, group3_value))
  device:send(Configuration:Set({parameter_number = 103, size = 4, configuration_value = group3_value}))

  -- Set reporting interval for each group to every 10 seconds for more responsive updates
  print("Setting reporting intervals to 10 seconds for all groups...")
  device:send(Configuration:Set({parameter_number = 111, size = 4, configuration_value = 10}))  -- Group 1 interval: 10 seconds
  device:send(Configuration:Set({parameter_number = 112, size = 4, configuration_value = 10}))  -- Group 2 interval: 10 seconds
  device:send(Configuration:Set({parameter_number = 113, size = 4, configuration_value = 10}))  -- Group 3 interval: 10 seconds

  -- Set parameter 4 (Threshold detection) to be more sensitive (report on smaller changes)
  print("Setting power change threshold to 1W for quicker updates...")
  device:send(Configuration:Set({parameter_number = 4, size = 1, configuration_value = 1}))  -- 1W threshold

  -- Enable automatic reporting mode (various parameters for different models)
  print("Enabling automatic reporting mode...")
  device:send(Configuration:Set({parameter_number = 255, size = 4, configuration_value = 1}))   -- 1=Enable, 0=Disable
  device:send(Configuration:Set({parameter_number = 90, size = 1, configuration_value = 1}))    -- Enable on some models
  device:send(Configuration:Set({parameter_number = 91, size = 2, configuration_value = 10}))   -- Report time in seconds

  -- Set up association groups for automatic reporting
  device.thread:call_with_delay(2, function() setup_automatic_reporting(device) end)

  print("Configuration complete - device should start reporting automatically")
  print("============================================")
end

-- Map endpoint to component
-- REVISED MAPPING BASED ON USER FEEDBACK:
-- EP 0 (src_channel=0) = Root device/Total combined reading (main component)
-- EP 1 (src_channel=1) = First physical clamp (clamp0 component)
-- EP 2 (src_channel=2) = Second physical clamp (clamp1 component)
-- EP 3 (src_channel=3) = Battery reporting (not used directly)
--
-- IMPORTANT: The Aeon HEM reports differently than expected
-- These are the actual mapping patterns observed in testing:
local function endpoint_to_component(device, ep)
  -- Debug print to track endpoint mapping
  print(string.format("Converting endpoint %d to component", ep))

  -- Map endpoints based on revised understanding
  if ep == 0 or ep == nil then
    -- EP0 (root) is Total
    print("  Mapping EP0 (root) to main component (Total readings)")
    return "main"
  elseif ep == 1 then
    -- EP1 is First Clamp
    print("  Mapping EP1 to clamp0 component (First Clamp)")
    return "clamp0"
  elseif ep == 2 then
    -- EP2 is Second Clamp
    print("  Mapping EP2 to clamp1 component (Second Clamp)")
    return "clamp1"
  elseif ep == 3 then
    -- EP3 is Battery - map to main as we don't have a battery component
    print("  Mapping EP3 (battery) to main component")
    return "main"
  else
    print("  Unknown endpoint, defaulting to main")
    return "main"  -- Fallback for unknown endpoints
  end
end

local function component_to_endpoint(device, component_id)
  -- Debug print to track component mapping
  print(string.format("Converting component %s to endpoint", component_id))

  -- Map components to endpoints based on revised understanding
  if component_id == "main" then
    print("  Mapping main component to EP0 (root/Total readings)")
    return {0}  -- main -> EP0 (Total/root readings)
  elseif component_id == "clamp0" then
    print("  Mapping clamp0 component to EP1 (First Clamp)")
    return {1}  -- clamp0 -> EP1 (First Clamp)
  elseif component_id == "clamp1" then
    print("  Mapping clamp1 component to EP2 (Second Clamp)")
    return {2}  -- clamp1 -> EP2 (Second Clamp)
  else
    print("  Unknown component, defaulting to EP0 (root)")
    return {0}  -- Default to endpoint 0 if no match
  end
end

local function meter_report_handler(self, device, cmd)
  -- Enhanced debugging with timestamp for tracking report frequency
  local timestamp = os.date("%H:%M:%S")
  print(string.format("[%s] METER REPORT RECEIVED: src_channel=%s, scale=%s, value=%s, precision=%s, meter_type=%s, rate_type=%s",
                      timestamp,
                      tostring(cmd.src_channel),
                      tostring(cmd.args.scale),
                      tostring(cmd.args.meter_value),
                      tostring(cmd.args.precision),
                      tostring(cmd.args.meter_type),
                      tostring(cmd.args.rate_type)))

  -- Dump payload bytes for advanced debugging
  if cmd.payload then
    local bytes = {}
    for i = 1, #cmd.payload do
      table.insert(bytes, string.format("%02X", string.byte(cmd.payload, i)))
    end
    print("[" .. timestamp .. "] Report payload: " .. table.concat(bytes, " "))
  end

  -- Handle all endpoints 0-3 (ignore 4 and above)
  local ep = cmd.src_channel -- This might be nil for root device reports
  if ep and ep > 3 then
    print("Ignoring report from endpoint " .. ep .. " (higher than 3)")
    return
  end

  -- Define clear labels for each endpoint based on revised understanding
  local reading_source
  if ep == nil or ep == 0 then
    reading_source = "ROOT DEVICE (Total Combined)"
  elseif ep == 1 then
    reading_source = "FIRST CLAMP"
  elseif ep == 2 then
    reading_source = "SECOND CLAMP"
  elseif ep == 3 then
    reading_source = "BATTERY"
    -- We don't handle battery reports currently
    print("Battery report received - not currently processed")
    return
  end

  -- Get corresponding component for this endpoint
  local component = endpoint_to_component(device, ep)

  -- Get the raw value from the meter report
  local value = cmd.args.meter_value

  -- Fix potential clamp value reporting issues
  -- ENHANCEMENT: Ensure non-zero values for individual clamps when they should have readings
  if (ep == 1 or ep == 2) and cmd.args.scale == Meter.scale.electric_meter.WATTS and value == 0 then
    -- Check if this might be a false zero reading
    print(string.format("WARNING: %s (EP%d) reported 0W, which may be incorrect. Check physical clamp connection.",
                      reading_source, ep))

    -- Don't apply any automatic correction, but log the issue for investigation
    -- We'll let zero values through to show in the UI since we're not sure
  end

  -- NOTE: We no longer multiply total watts by 10 as this was causing incorrect readings
  -- Just use the value directly as reported by the device
  if (ep == nil or ep == 0) and cmd.args.scale == Meter.scale.electric_meter.WATTS then
    print(string.format("NOTE: Using raw watts value %s directly as reported by the device", value))
  end

  print(string.format("REPORT: %s (EP%d) -> component '%s': scale=%s, value=%s",
                     reading_source, ep, component, cmd.args.scale, value))

  -- Check if the component actually exists in the device profile
  if device.profile.components[component] == nil then
    print(string.format("ERROR: Component %s doesn't exist in device profile", component))
    component = "main" -- Fallback to main component
    print(string.format("FALLBACK: Using main component instead"))
  end

  local unit, capability_id, attribute_id
  if cmd.args.scale == Meter.scale.electric_meter.KILOWATT_HOURS then
    unit = "kWh"
    capability_id = "energyMeter"
    attribute_id = "energy"
  elseif cmd.args.scale == Meter.scale.electric_meter.WATTS then
    unit = "W"
    capability_id = "powerMeter"
    attribute_id = "power"
  else
    print(string.format("WARNING: Unknown scale %s, skipping report", tostring(cmd.args.scale)))
    return
  end

  -- Skip reporting if value is outside reasonable range
  if (unit == "W" and (value < 0 or value > 50000)) or
     (unit == "kWh" and (value < 0 or value > 100000)) then
    print(string.format("WARNING: Unreasonable value %s %s detected, skipping report", value, unit))
    return
  end

  print(string.format("EMIT: %s.%s event to '%s' component: %s %s",
                     capability_id, attribute_id, component, value, unit))

  -- Use emit_component_event which is safer
  if capability_id == "energyMeter" then
    device:emit_component_event(
      device.profile.components[component],
      capabilities.energyMeter.energy({ value = value, unit = unit })
    )
  else -- powerMeter
    device:emit_component_event(
      device.profile.components[component],
      capabilities.powerMeter.power({ value = value, unit = unit })
    )
  end
end

-- Function to check association groups to verify automatic reporting
local function check_associations(device)
  print("====== CHECKING ASSOCIATION GROUPS ======")
  print("Verifying association group configuration for automatic reporting...")
  device:send(Association:Get({grouping_identifier = 1}))
  device:send(Association:Get({grouping_identifier = 2}))
  device:send(Association:Get({grouping_identifier = 3}))
  device:send(Association:Get({grouping_identifier = 4}))
  print("============================================")
end

-- Function to force immediate reports from the device
local function force_reporting(device)
  print("====== FORCING IMMEDIATE REPORTS ======")

  -- Send a series of Get commands to all endpoints
  print("Requesting immediate readings from all endpoints...")
  local endpoints = {0, 1, 2, 3}

  for _, ep in ipairs(endpoints) do
    print(string.format("Requesting reports from endpoint %d", ep))
    device:send(Meter:Get({scale = Meter.scale.electric_meter.WATTS}, {dst_channels = {ep}}))
    device.thread:call_with_delay(0.5, function()
      device:send(Meter:Get({scale = Meter.scale.electric_meter.KILOWATT_HOURS}, {dst_channels = {ep}}))
    end)
  end

  print("All report requests sent")
  print("============================================")
end

local function refresh_handler(driver, device, cmd)
  print("====== REFRESH: Aeon Home Energy Meter ======")
  print("Available components in device profile:")
  for id, comp in pairs(device.profile.components) do
    print("  - " .. id)
  end

  -- Define clear mapping of endpoints to readings based on revised understanding
  local endpoints = {
    {id = 0, label = "ROOT DEVICE (Total Combined)", component = "main"},
    {id = 1, label = "FIRST CLAMP", component = "clamp0"},
    {id = 2, label = "SECOND CLAMP", component = "clamp1"}
    -- Endpoint 3 is for battery reports, we don't need to query it
  }

  -- Request power and energy values from each endpoint
  for _, ep_info in ipairs(endpoints) do
    local ep = ep_info.id
    local label = ep_info.label
    local component = ep_info.component

    print(string.format("REQUEST: %s (EP%d) -> component '%s'", label, ep, component))

    -- Make sure the component exists
    if device.profile.components[component] then
      -- Using send with endpoint specification for better reliability
      print(string.format("  Sending WATTS query to endpoint %d", ep))
      device:send(Meter:Get({scale = Meter.scale.electric_meter.WATTS}, {dst_channels = {ep}}))
      print(string.format("  Sending kWh query to endpoint %d", ep))
      device:send(Meter:Get({scale = Meter.scale.electric_meter.KILOWATT_HOURS}, {dst_channels = {ep}}))
    else
      print(string.format("WARNING: Component %s not found in device profile", component))
    end
  end

  -- Also verify association groups are configured correctly for automatic reporting
  device.thread:call_with_delay(1, function() check_associations(device) end)

  -- Force immediate reports
  device.thread:call_with_delay(3, function() force_reporting(device) end)

  print("============================================")
end

-- Handle Configuration Reports
local function configuration_report_handler(self, device, cmd)
  local timestamp = os.date("%H:%M:%S")
  print(string.format("[%s] CONFIGURATION REPORT: Parameter %d = %d (0x%02X)",
                    timestamp,
                    cmd.args.parameter_number,
                    cmd.args.configuration_value,
                    cmd.args.configuration_value))
end

-- Polling mechanism - easily removable
-- BEGIN POLLING CODE BLOCK --
local POLLING_TIMER_KEY = "polling_timer"

-- Default polling configuration
local DEFAULT_POLLING_INTERVAL = 60 -- in seconds
local DEFAULT_POLLING_ENABLED = false

-- Function to handle polling
local function poll_device(driver, device)
  local timestamp = os.date("%H:%M:%S")
  print(string.format("[%s] POLLING: Executing scheduled poll of Aeon meter", timestamp))

  -- Request readings from all endpoints
  local endpoints = {0, 1, 2}  -- We only poll main and the two clamps

  for _, ep in ipairs(endpoints) do
    print(string.format("  Polling endpoint %d for watts and kWh", ep))
    device:send(Meter:Get({scale = Meter.scale.electric_meter.WATTS}, {dst_channels = {ep}}))
    device:send(Meter:Get({scale = Meter.scale.electric_meter.KILOWATT_HOURS}, {dst_channels = {ep}}))
  end

  -- Schedule next poll if polling is still enabled
  local interval = device.preferences.pollingInterval or DEFAULT_POLLING_INTERVAL
  local enabled = device.preferences.pollingEnabled or DEFAULT_POLLING_ENABLED

  if enabled then
    print(string.format("  Scheduling next poll in %d seconds", interval))
    local timer = device.thread:call_with_delay(interval, function() poll_device(driver, device) end)
    device:set_field(POLLING_TIMER_KEY, timer)
  else
    print("  Polling disabled, not scheduling next poll")
  end
end

-- Function to start or stop polling based on preferences
local function update_polling(driver, device)
  -- Cancel any existing polling timer
  local existing_timer = device:get_field(POLLING_TIMER_KEY)
  if existing_timer then
    device.thread:cancel_timer(existing_timer)
    device:set_field(POLLING_TIMER_KEY, nil)
    print("Cancelled existing polling timer")
  end

  -- Start new polling if enabled
  local interval = device.preferences.pollingInterval or DEFAULT_POLLING_INTERVAL
  local enabled = device.preferences.pollingEnabled or DEFAULT_POLLING_ENABLED

  if enabled then
    print(string.format("Polling enabled - starting polling with interval %d seconds", interval))
    local timer = device.thread:call_with_delay(interval, function() poll_device(driver, device) end)
    device:set_field(POLLING_TIMER_KEY, timer)
  else
    print("Polling disabled")
  end
end
-- END POLLING CODE BLOCK --

local aeon_meter = {
  zwave_handlers = {
    [cc.METER] = {
      [Meter.REPORT] = meter_report_handler
    },
    [cc.ASSOCIATION] = {
      [Association.REPORT] = association_report_handler
    },
    [cc.CONFIGURATION] = {
      [Configuration.REPORT] = configuration_report_handler
    }
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler
    }
  },
  lifecycle_handlers = {
    doConfigure = do_configure,
    init = function(self, device)
      device:set_component_to_endpoint_fn(component_to_endpoint)
      device:set_endpoint_to_component_fn(endpoint_to_component)

      -- Log which components are in the profile
      print("Available components in profile:")
      for id, _ in pairs(device.profile.components) do
        print("- " .. id)
      end

      -- Run full configuration on init to ensure automatic reporting is set up
      device.thread:call_with_delay(1, function() do_configure(self, device) end)

      -- Then poll device for initial values
      device.thread:call_with_delay(5, function() refresh_handler(self, device) end)

      -- After initial setup, verify configuration was applied
      device.thread:call_with_delay(10, function()
        -- Check configuration parameters
        print("Verifying configuration parameters...")
        device:send(Configuration:Get({parameter_number = 4}))
        device:send(Configuration:Get({parameter_number = 90}))
        device:send(Configuration:Get({parameter_number = 101}))
        device:send(Configuration:Get({parameter_number = 102}))
        device:send(Configuration:Get({parameter_number = 111}))
        device:send(Configuration:Get({parameter_number = 112}))

        -- Check associations
        check_associations(device)

        -- Initialize polling based on preferences
        update_polling(self, device)
      end)
    end,
    added = function(self, device)
      -- Request initial readings when device is added (with a delay)
      device.thread:call_with_delay(2, function() refresh_handler(self, device) end)
    end,
    infoChanged = function(self, device, event, args)
      -- If device information changes (like profile), ensure endpoints are properly setup
      device:set_component_to_endpoint_fn(component_to_endpoint)
      device:set_endpoint_to_component_fn(endpoint_to_component)

      -- Handle preference changes
      if args.old_st_store.preferences then
        local old_polling_enabled = args.old_st_store.preferences.pollingEnabled or DEFAULT_POLLING_ENABLED
        local old_polling_interval = args.old_st_store.preferences.pollingInterval or DEFAULT_POLLING_INTERVAL

        local new_polling_enabled = device.preferences.pollingEnabled or DEFAULT_POLLING_ENABLED
        local new_polling_interval = device.preferences.pollingInterval or DEFAULT_POLLING_INTERVAL

        -- Check if polling settings changed
        if old_polling_enabled ~= new_polling_enabled or old_polling_interval ~= new_polling_interval then
          print(string.format("Polling settings changed: enabled=%s, interval=%d",
                             tostring(new_polling_enabled), new_polling_interval))
          update_polling(self, device)
        end
      end
    end,

    removed = function(self, device)
      -- Clean up polling timer when device is removed
      local timer = device:get_field(POLLING_TIMER_KEY)
      if timer then
        print("Device removed: Cleaning up polling timer")
        device.thread:cancel_timer(timer)
        device:set_field(POLLING_TIMER_KEY, nil)
      end
    end
  },
  NAME = "aeon meter",
  can_handle = can_handle_aeon_meter,

  -- Define device preferences that will appear in the SmartThings app
  preferences = {
    {
      -- Preference for enabling/disabling polling
      name = "pollingEnabled",
      title = "Enable polling (manual data requests)",
      description = "Enable periodic polling of the meter for readings. This is separate from the device's automatic reporting.",
      type = "bool",
      default = false,
      required = false
    },
    {
      -- Preference for setting the polling interval
      name = "pollingInterval",
      title = "Polling interval (seconds)",
      description = "How often the hub should request readings from the meter (in seconds)",
      type = "number",
      min = 10,
      max = 3600,
      default = 60,
      required = false
    }
  }
}

return aeon_meter
