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

local capabilities = require "st.capabilities"
--- @type st.zwave.defaults
local defaults = require "st.zwave.defaults"
--- @type st.zwave.Driver
local ZwaveDriver = require "st.zwave.driver"
local utils = require "st.utils"

local device_added = function (self, device)
  print("Device added: " .. device.id)
  print("Manufacturer: " .. (device.manufacturer_name or "unknown"))
  print("Model: " .. (device.model or "unknown"))
  
  -- Attempt to register the device's preferences
  for _, subdriver in ipairs(self.sub_drivers) do
    if subdriver.preferences and subdriver.can_handle and subdriver:can_handle({}, self, device) then
      print("Found matching subdriver with preferences")
      device:set_field("subdriver_preferences", subdriver.preferences)
      
      -- Store update_polling handler if available
      if subdriver.update_polling then
        device:set_field("update_polling_handler", subdriver.update_polling)
      end
      
      break
    end
  end
  
  -- Refresh the device to get initial readings
  device:refresh()
end

-- This function explicitly merges preferences from subdrivers into the main driver
local function merge_subdriver_preferences(driver)
  local all_preferences = {}
  
  -- Loop through all registered subdrivers to collect preferences
  for _, subdriver_path in ipairs({ 
    "aeon-meter",
    "aeotec-gen5-meter",
    "qubino-meter" 
  }) do
    local success, subdriver = pcall(require, subdriver_path)
    if success and subdriver and subdriver.preferences then
      print("Found preferences in subdriver: " .. subdriver_path)
      
      -- Add each preference from this subdriver
      for _, pref in ipairs(subdriver.preferences) do
        local pref_copy = utils.deep_copy(pref)
        -- Add subdriver identifier to preference name to avoid conflicts
        pref_copy.name = subdriver_path:gsub("-", "_") .. "_" .. pref_copy.name
        table.insert(all_preferences, pref_copy)
      end
    end
  end
  
  -- Set the collected preferences on the driver
  if #all_preferences > 0 then
    print("Setting " .. #all_preferences .. " preferences on driver")
    driver.preferences = all_preferences
  end
end
  for _, subdriver_module in ipairs(driver.sub_drivers) do
    local subdriver = require(subdriver_module)
    if subdriver.preferences then
      print("Found preferences in subdriver: " .. (subdriver.NAME or "unnamed"))
      for _, pref in ipairs(subdriver.preferences) do
        table.insert(all_preferences, pref)
      end
    end
  end
  
  -- Set the merged preferences on the driver template
  if #all_preferences > 0 then
    print("Setting " .. #all_preferences .. " preferences from subdrivers")
    driver_template.preferences = all_preferences
  else
    print("No preferences found in subdrivers")
    driver_template.preferences = {
      {
        name = "dummyPref",
        title = "Settings",
        description = "Device settings",
        type = "boolean",
        default = false,
        required = false
      }
    }
  end
end

local info_changed = function (self, device, event, args)
  print("Info changed at driver level:")
  print("Device: " .. device.id)
  print("Profile: " .. device.profile.name)
  
  -- Directly handle preference changes at the driver level
  if args.old_st_store and args.old_st_store.preferences then
    print("Preferences changed - checking for handlers")
    print("New preferences: " .. utils.stringify_table(device.preferences))
    
    -- Try to update polling if there's a handler
    local update_polling = device:get_field("update_polling_handler")
    if update_polling then
      print("Calling update_polling handler")
      update_polling(self, device)
    end
    
    -- Try to apply other configuration changes if needed
    local configure_handler = device:get_field("configure_handler")
    if configure_handler then
      print("Calling configure handler")
      configure_handler(self, device, {args = {}})
    end
  end
end

local device_init = function(self, device)
  print("Device initialized: " .. device.id)
  
  -- Try to find the appropriate subdriver for this device
  local subdriver = nil
  for _, sub in ipairs(self.sub_drivers) do
    if sub.can_handle and sub:can_handle({}, self, device) then
      subdriver = sub
      break
    end
  end
  
  -- If we found a matching subdriver, store its preferences
  if subdriver then
    print("Found matching subdriver: " .. (subdriver.NAME or "unnamed"))
    
    -- Save subdriver-specific handlers and preferences
    if subdriver.preferences then
      print("Setting device-specific preferences from subdriver")
      device:set_field("subdriver_preferences", subdriver.preferences)
    end
    
    if subdriver.update_polling then
      device:set_field("update_polling_handler", subdriver.update_polling)
    end
    
    if subdriver.configuration_handler then
      device:set_field("configure_handler", subdriver.configuration_handler)
    end
  end
end

local driver_template = {
  supported_capabilities = {
    capabilities.powerMeter,
    capabilities.energyMeter,
    capabilities.refresh,
    capabilities.configuration
  },
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    infoChanged = info_changed
  },
  sub_drivers = {
    require("qubino-meter"),
    require("aeotec-gen5-meter"),
    require("aeon-meter")
  },
  capability_handlers = {
    [capabilities.configuration.ID] = {
      [capabilities.configuration.commands.configure.NAME] = function(driver, device, command)
        -- Handle configuration at top level by delegating to the appropriate sub-driver
        -- This ensures preference handling is properly routed
        print("Configure command received at driver level")

        local handler = device:get_field("configure_handler")
        if handler then
          print("Delegating to sub-driver configure handler")
          handler(driver, device, command)
        else
          -- If no specific handler is found, apply basic configuration
          print("No sub-driver handler found, applying generic configuration")
          device:refresh()
        end
      end
    }
  },

  -- We don't define preferences at the driver level - instead we'll let each subdriver
  -- define its own preferences. This is key because the driver only shows preferences
  -- defined at the top level, even when the preferences are properly defined in subdrivers.
  
  -- Add a dummy preference handler to force the UI to show the settings menu
  preferences = {}  -- Empty preferences to be populated during runtime
}

-- Merge preferences from subdrivers before registering
merge_subdriver_preferences(driver_template)

defaults.register_for_default_handlers(driver_template, driver_template.supported_capabilities)
--- @type st.zwave.Driver
local electricMeter = ZwaveDriver("zwave_electric_meter", driver_template)

-- Override the find_subdriver method to ensure preferences are registered
local original_find_subdriver = electricMeter.find_driver_handler
electricMeter.find_driver_handler = function(self, device, ...)
  local subdriver = original_find_subdriver(self, device, ...)
  
  -- If we found a matching subdriver, store its preferences for this device
  if subdriver and subdriver.preferences then
    print("Setting device-specific preferences from subdriver")
    device:set_field("subdriver_preferences", subdriver.preferences)
  end
  
  return subdriver
end

-- Run the driver
electricMeter:run()
