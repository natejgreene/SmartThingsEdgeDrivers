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

-- Constants for polling functionality
local POLLING_TIMER_KEY = "polling_timer"
local DEFAULT_POLLING_INTERVAL = 15 -- in seconds
local DEFAULT_POLLING_ENABLED = true

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

local function association_report_handler(self, device, cmd)
  if #cmd.args.node_ids == 0 then
    print("Association Group " .. cmd.args.grouping_identifier .. ": No nodes - reporting won't work")
  end
end

local function setup_automatic_reporting(device)
  local node_ids = {0x01}
  device:send(Association:Set({grouping_identifier = 1, node_ids = node_ids}))

  device.thread:call_with_delay(2, function()
    device:send(Association:Get({grouping_identifier = 1}))
  end)
end

local do_configure = function (self, device)
  -- Configure all reporting with a single parameter
  -- Value 6195 (0x1833) enables all necessary reporting features
  device:send(Configuration:Set({parameter_number = 101, size = 4, configuration_value = 6195}))

  -- Set reporting interval to 10 seconds
  device:send(Configuration:Set({parameter_number = 111, size = 4, configuration_value = 10}))

  -- Set power change threshold to 1W for more responsive reports
  device:send(Configuration:Set({parameter_number = 4, size = 1, configuration_value = 1}))

  -- Set up association
  device.thread:call_with_delay(2, function() setup_automatic_reporting(device) end)

  print("Configuration complete - device should start reporting automatically")
  print("============================================")
end

local function endpoint_to_component(device, ep)
  if ep == 0 or ep == nil then
    return "main"
  elseif ep == 1 then
    return "clamp1"
  elseif ep == 2 then
    return "clamp2"
  elseif ep == 3 then
    return "main"  -- Map battery to main
  else
    return "main"
  end
end

local function component_to_endpoint(device, component_id)
  if component_id == "main" then
    return {0}
  elseif component_id == "clamp1" then
    return {1}
  elseif component_id == "clamp2" then
    return {2}
  else
    return {0}
  end
end

local function meter_report_handler(self, device, cmd)
  local ep = cmd.src_channel
  if ep and ep > 2 then
    return
  end

  local component = endpoint_to_component(device, ep)
  local value = cmd.args.meter_value

  if device.profile.components[component] == nil then
    component = "main" -- Fallback to main component
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
    return
  end

  -- Skip reporting if value is outside reasonable range
  if (unit == "W" and (value < 0 or value > 50000)) or
     (unit == "kWh" and (value < 0 or value > 100000)) then
    return
  end

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

local function force_reporting(device)
  local endpoints = {0, 1, 2, 3}

  for _, ep in ipairs(endpoints) do
    device:send(Meter:Get({scale = Meter.scale.electric_meter.WATTS}, {dst_channels = {ep}}))
    device.thread:call_with_delay(0.5, function()
      device:send(Meter:Get({scale = Meter.scale.electric_meter.KILOWATT_HOURS}, {dst_channels = {ep}}))
    end)
  end
end

local function refresh_handler(driver, device, cmd)
  local endpoints = {
    {id = 0, component = "main"},
    {id = 1, component = "clamp1"},
    {id = 2, component = "clamp2"}
  }

  for _, ep_info in ipairs(endpoints) do
    local ep = ep_info.id
    local component = ep_info.component

    if device.profile.components[component] then
      device:send(Meter:Get({scale = Meter.scale.electric_meter.WATTS}, {dst_channels = {ep}}))
      device:send(Meter:Get({scale = Meter.scale.electric_meter.KILOWATT_HOURS}, {dst_channels = {ep}}))
    end
  end

  -- Force immediate reports
  device.thread:call_with_delay(3, function() force_reporting(device) end)
end

local function configuration_report_handler(self, device, cmd)
  -- Nothing to do, just handle the report
end

-- Polling mechanism - easily removable
-- BEGIN POLLING CODE BLOCK --

local function poll_device(driver, device)
  local endpoints = {0, 1, 2}

  for _, ep in ipairs(endpoints) do
    device:send(Meter:Get({scale = Meter.scale.electric_meter.WATTS}, {dst_channels = {ep}}))
    device:send(Meter:Get({scale = Meter.scale.electric_meter.KILOWATT_HOURS}, {dst_channels = {ep}}))
  end

  local interval = device.preferences.aeon_meter_pollingInterval or device.preferences.pollingInterval
  if interval == nil then interval = DEFAULT_POLLING_INTERVAL end

  local enabled = device.preferences.aeon_meter_pollingEnabled or device.preferences.pollingEnabled
  if enabled == nil then enabled = DEFAULT_POLLING_ENABLED end

  if enabled then
    local timer = device.thread:call_with_delay(interval, function() poll_device(driver, device) end)
    device:set_field(POLLING_TIMER_KEY, timer)
  end
end

local function update_polling(driver, device)
  local existing_timer = device:get_field(POLLING_TIMER_KEY)
  if existing_timer then
    device.thread:cancel_timer(existing_timer)
    device:set_field(POLLING_TIMER_KEY, nil)
  end

  local enabled = device.preferences.aeon_meter_pollingEnabled or device.preferences.pollingEnabled
  if enabled == nil then enabled = DEFAULT_POLLING_ENABLED end

  local interval = device.preferences.aeon_meter_pollingInterval or device.preferences.pollingInterval
  if interval == nil then interval = DEFAULT_POLLING_INTERVAL end

  if interval < 10 then interval = 10 end
  if interval > 3600 then interval = 3600 end

  if enabled then
    local timer = device.thread:call_with_delay(interval, function() poll_device(driver, device) end)
    device:set_field(POLLING_TIMER_KEY, timer)
  end
end

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
    },
    [capabilities.configuration.ID] = {
      [capabilities.configuration.commands.configure.NAME] = function(driver, device, command)
        print("Configuration command received in aeon-meter subdriver")
        -- Store a reference to this handler so the main driver can delegate to it
        device:set_field("configure_handler", function(d, dev, cmd)
          do_configure(driver, device)
        end)
        do_configure(driver, device)
      end
    }
  },
  lifecycle_handlers = {
    doConfigure = do_configure,
    init = function(self, device)
      print("INITIALIZING Aeon Meter device handler")
      print("Device ID:", device.id)
      print("Device Type:", device.device_network_id)
      print("Device Profile:", device.profile.name)
      print("Available preferences:", utils.stringify_table(device.preferences))
      print("Available components:", utils.stringify_table(device.profile.components))

      device:set_component_to_endpoint_fn(component_to_endpoint)
      device:set_endpoint_to_component_fn(endpoint_to_component)

      device.thread:call_with_delay(1, function() do_configure(self, device) end)
      device.thread:call_with_delay(5, function() refresh_handler(self, device) end)
      device.thread:call_with_delay(8, function() update_polling(self, device) end)

      device.thread:call_with_delay(10, function()
        device:send(Configuration:Get({parameter_number = 101}))
        update_polling(self, device)
      end)
    end,
    added = function(self, device)
      device.thread:call_with_delay(2, function() refresh_handler(self, device) end)
    end,
    infoChanged = function(self, device, event, args)
      print("INFO CHANGED called in aeon-meter subdriver")
      print("Current preferences:", utils.stringify_table(device.preferences))
      print("Event:", utils.stringify_table(event))
      print("Args:", utils.stringify_table(args))

      device:set_component_to_endpoint_fn(component_to_endpoint)
      device:set_endpoint_to_component_fn(endpoint_to_component)

      if args.old_st_store and args.old_st_store.preferences then
        print("Processing preference change")
        
        -- Check both naming conventions for preferences
        local old_polling_enabled = args.old_st_store.preferences.aeon_meter_pollingEnabled or args.old_st_store.preferences.pollingEnabled
        if old_polling_enabled == nil then old_polling_enabled = DEFAULT_POLLING_ENABLED end

        local old_polling_interval = args.old_st_store.preferences.aeon_meter_pollingInterval or args.old_st_store.preferences.pollingInterval
        if old_polling_interval == nil then old_polling_interval = DEFAULT_POLLING_INTERVAL end

        local new_polling_enabled = device.preferences.aeon_meter_pollingEnabled or device.preferences.pollingEnabled
        if new_polling_enabled == nil then new_polling_enabled = DEFAULT_POLLING_ENABLED end

        local new_polling_interval = device.preferences.aeon_meter_pollingInterval or device.preferences.pollingInterval
        if new_polling_interval == nil then new_polling_interval = DEFAULT_POLLING_INTERVAL end

        print(string.format("Polling settings change: %s -> %s, %d -> %d", 
                           tostring(old_polling_enabled), tostring(new_polling_enabled),
                           old_polling_interval, new_polling_interval))

        if old_polling_enabled ~= new_polling_enabled or old_polling_interval ~= new_polling_interval then
          print("Updating polling settings based on preference change")
          update_polling(self, device)
        end
      end
    end,
    removed = function(self, device)
      local timer = device:get_field(POLLING_TIMER_KEY)
      if timer then
        device.thread:cancel_timer(timer)
        device:set_field(POLLING_TIMER_KEY, nil)
      end
    end
  },
  NAME = "aeon_meter",
  can_handle = can_handle_aeon_meter,

  preferences = {
    {
      name = "pollingEnabled",
      title = "Enable polling",
      description = "Enable periodic polling of the meter for readings",
      type = "boolean",
      default = DEFAULT_POLLING_ENABLED,
      required = false
    },
    {
      name = "pollingInterval",
      title = "Polling interval (seconds)",
      description = "How often the hub should request readings (in seconds)",
      type = "number",
      min = 10,
      max = 3600,
      default = DEFAULT_POLLING_INTERVAL,
      required = false
    }
  }
}

return aeon_meter
