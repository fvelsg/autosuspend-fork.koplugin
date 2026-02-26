local Device = require("device")

-- If a device can power off or go into standby, it can also suspend ;).
if not Device:canSuspend() then
    return { disabled = true, }
end

local Math = require("optmath")
local NetworkMgr = require("ui/network/manager")
local PluginShare = require("pluginshare")
local PowerD = Device:getPowerDevice()
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local datetime = require("datetime")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

local default_autoshutdown_timeout_seconds = 3*24*60*60 -- three days
local default_auto_suspend_timeout_seconds = 15*60 -- 15 minutes
local default_auto_standby_timeout_seconds = 4 -- 4 seconds; should be safe on Kobo/Sage
local default_standby_timeout_after_resume_seconds = 4 -- 4 seconds; should be safe on Kobo/Sage, not customizable
local default_kindle_t1_timeout_reset_seconds = 5*60 -- 5 minutes (i.e., half of the standard t1 timeout).

local AutoSuspend = WidgetContainer:extend{
    name = "autosuspend",
    is_doc_only = false,
    autoshutdown_timeout_seconds = default_autoshutdown_timeout_seconds,
    auto_suspend_timeout_seconds = default_auto_suspend_timeout_seconds,
    auto_standby_timeout_seconds = default_auto_standby_timeout_seconds,
    last_action_time = 0,
    is_standby_scheduled = nil,
    task = nil,
    kindle_task = nil,
    standby_task = nil,
    going_to_suspend = nil,
}

function AutoSuspend:_enabledStandby()
    return Device:canStandby() and self.auto_standby_timeout_seconds > 0
end

function AutoSuspend:_enabled()
    -- NOTE: Plugin is only enabled if Device:canSuspend(), so we can elide the check here
    return self.auto_suspend_timeout_seconds > 0
end

function AutoSuspend:_enabledShutdown()
    return Device:canPowerOff() and self.autoshutdown_timeout_seconds > 0
end

function AutoSuspend:_schedule(shutdown_only)
    if not self:_enabled() and not self:_enabledShutdown() then
        logger.dbg("AutoSuspend: suspend/shutdown timer is disabled")
        return
    end

    local suspend_delay_seconds, shutdown_delay_seconds
    local is_charging
    -- On devices with an auxiliary battery, we only care about the auxiliary battery being charged...
    if Device:hasAuxBattery() and PowerD:isAuxBatteryConnected() then
        is_charging = PowerD:isAuxCharging() and not PowerD:isAuxCharged()
    else
        is_charging = PowerD:isCharging() and not PowerD:isCharged()
    end
    -- We *do* want to make sure we attempt to go into suspend/shutdown again while *fully* charged, though.
    if PluginShare.pause_auto_suspend or is_charging then
        suspend_delay_seconds = self.auto_suspend_timeout_seconds
        shutdown_delay_seconds = self.autoshutdown_timeout_seconds
    else
        local now = UIManager:getElapsedTimeSinceBoot()
        suspend_delay_seconds = self.auto_suspend_timeout_seconds - time.to_number(now - self.last_action_time)
        shutdown_delay_seconds = self.autoshutdown_timeout_seconds - time.to_number(now - self.last_action_time)
    end

    -- Try to shutdown first, as we may have been woken up from suspend just for the sole purpose of doing that.
    if self:_enabledShutdown() and shutdown_delay_seconds <= 0 then
        logger.dbg("AutoSuspend: initiating shutdown")
        UIManager:poweroff_action()
    elseif self:_enabled() and suspend_delay_seconds <= 0 and not shutdown_only then
        logger.dbg("AutoSuspend: will suspend the device")
        UIManager:suspend()
    else
        if self:_enabled() and not shutdown_only then
            logger.dbg("AutoSuspend: scheduling next suspend check in", suspend_delay_seconds)
            UIManager:scheduleIn(suspend_delay_seconds, self.task)
        end
        if self:_enabledShutdown() then
            logger.dbg("AutoSuspend: scheduling next shutdown check in", shutdown_delay_seconds)
            UIManager:scheduleIn(shutdown_delay_seconds, self.task)
        end
    end
end

function AutoSuspend:_unschedule()
    if self.task then
        logger.dbg("AutoSuspend: unschedule suspend/shutdown timer")
        UIManager:unschedule(self.task)
    end
end

function AutoSuspend:_start()
    if self:_enabled() or self:_enabledShutdown() then
        logger.dbg("AutoSuspend: start suspend/shutdown timer at", time.format_time(self.last_action_time))
        self:_schedule()
    end
end

function AutoSuspend:_start_standby(sleep_in)
    if self:_enabledStandby() then
        logger.dbg("AutoSuspend: start standby timer at", time.format_time(self.last_action_time))
        self:_schedule_standby(sleep_in)
    end
end

-- Variant that only re-engages the shutdown timer for onUnexpectedWakeupLimit
function AutoSuspend:_restart()
    if self:_enabledShutdown() then
        logger.dbg("AutoSuspend: restart shutdown timer at", time.format_time(self.last_action_time))
        self:_schedule(true)
    end
end

if Device:isKindle() then
    function AutoSuspend:_schedule_kindle()
        local now = UIManager:getElapsedTimeSinceBoot()
        local kindle_t1_reset_seconds = default_kindle_t1_timeout_reset_seconds - time.to_number(now - self.last_t1_reset_time)
        
        local suspend_delay_seconds = 0
        if self:_enabled() then
            suspend_delay_seconds = self.auto_suspend_timeout_seconds - time.to_number(now - self.last_action_time)
        end

        -- Keep resetting T1 if autosuspend is explicitly disabled, OR if we haven't hit the suspend limit yet
        if (not self:_enabled()) or (suspend_delay_seconds > 0) then
            if kindle_t1_reset_seconds <= 0 then
                logger.dbg("AutoSuspend: will reset the system's t1 timeout, re-scheduling check")
                PowerD:resetT1Timeout()
                self.last_t1_reset_time = UIManager:getElapsedTimeSinceBoot()
                UIManager:scheduleIn(default_kindle_t1_timeout_reset_seconds, self.kindle_task)
            else
                logger.dbg("AutoSuspend: scheduling next t1 timeout check in", kindle_t1_reset_seconds)
                UIManager:scheduleIn(kindle_t1_reset_seconds, self.kindle_task)
            end
        else
            logger.dbg("AutoSuspend: t1 timeout timer is stopped (suspending soon)")
        end
    end

    function AutoSuspend:_unschedule_kindle()
        if self.kindle_task then
            logger.dbg("AutoSuspend: unschedule t1 timeout timer")
            UIManager:unschedule(self.kindle_task)
        end
    end

    function AutoSuspend:_start_kindle()
        -- Always boot up the heartbeat so infinite awake mode works
        logger.dbg("AutoSuspend: start t1 timeout timer at", time.format_time(self.last_action_time))
        self:_schedule_kindle()
    end
else
    -- NOP these on other platforms to avoid a proliferation of Device:isKindle() checks everywhere
    function AutoSuspend:_schedule_kindle() end
    function AutoSuspend:_unschedule_kindle() end
    function AutoSuspend:_start_kindle() end
end

function AutoSuspend:init()
    logger.dbg("AutoSuspend: init")
    PluginShare.live_autosuspend = self
    self.autoshutdown_timeout_seconds = G_reader_settings:readSetting("autoshutdown_timeout_seconds",
        default_autoshutdown_timeout_seconds)
    self.auto_suspend_timeout_seconds = G_reader_settings:readSetting("auto_suspend_timeout_seconds",
        default_auto_suspend_timeout_seconds)
    -- Disabled, until the user opts in.
    self.auto_standby_timeout_seconds = G_reader_settings:readSetting("auto_standby_timeout_seconds", -1)

    -- We only want those to exist as *instance* members
    self.is_standby_scheduled = false
    self.going_to_suspend = false

    UIManager.event_hook:registerWidget("InputEvent", self)
    -- We need an instance-specific function reference to schedule, because in some rare cases,
    -- we may instantiate a new plugin instance *before* tearing down the old one.
    self.task = function(shutdown_only)
        self:_schedule(shutdown_only)
    end
    if Device:isKindle() then
        self.last_t1_reset_time = UIManager:getElapsedTimeSinceBoot()
        self.kindle_task = function()
            self:_schedule_kindle()
        end
    end
    self.standby_task = function()
        self:_schedule_standby()
    end

    -- Make sure we only have an AllowStandby handler when we actually want one...
    self:toggleStandbyHandler(self:_enabledStandby())

    self.last_action_time = UIManager:getElapsedTimeSinceBoot()
    self:_start()
    self:_start_kindle()
    self:_start_standby()

    -- self.ui is nil in the testsuite
    if not self.ui or not self.ui.menu then return end
    self.ui.menu:registerToMainMenu(self)
end

function AutoSuspend:onCloseWidget()
    logger.dbg("AutoSuspend: onCloseWidget")

    self:_unschedule()
    self.task = nil

    self:_unschedule_kindle()
    self.kindle_task = nil

    self:_unschedule_standby()
    self.standby_task = nil
end

function AutoSuspend:onInputEvent()
    logger.dbg("AutoSuspend: onInputEvent")
    self.last_action_time = UIManager:getElapsedTimeSinceBoot()
end

function AutoSuspend:_unschedule_standby()
    if self.is_standby_scheduled and self.standby_task then
        logger.dbg("AutoSuspend: unschedule standby timer")
        UIManager:unschedule(self.standby_task)
        -- Restore the UIManager balance, as we run preventStandby right after scheduling this task.
        UIManager:allowStandby()

        self.is_standby_scheduled = false
    end
end

function AutoSuspend:_schedule_standby(sleep_in)
    sleep_in = sleep_in or self.auto_standby_timeout_seconds

    -- Start the long list of conditions in which we do *NOT* want to go into standby ;).
    if not Device:canStandby() or self.going_to_suspend then
        return
    end

    if self.auto_standby_timeout_seconds <= 0 then
        logger.dbg("AutoSuspend: No timeout set, no standby")
        return
    end

    local standby_delay_seconds
    if NetworkMgr:getWifiState() then
        standby_delay_seconds = sleep_in
    elseif Device.powerd:isCharging() and not Device:canPowerSaveWhileCharging() then
        standby_delay_seconds = sleep_in
    else
        local now = UIManager:getElapsedTimeSinceBoot()
        standby_delay_seconds = sleep_in - time.to_number(now - self.last_action_time)

        if not self.is_standby_scheduled and standby_delay_seconds <= 0 then
            standby_delay_seconds = sleep_in
        end
    end

    if standby_delay_seconds <= 0 then
        self:allowStandby()
    else
        logger.dbg("AutoSuspend: scheduling next standby check in", standby_delay_seconds)
        UIManager:scheduleIn(standby_delay_seconds, self.standby_task)

        if not self.is_standby_scheduled then
            self:preventStandby()
        end

        self.is_standby_scheduled = true
    end
end

function AutoSuspend:preventStandby()
    logger.dbg("AutoSuspend: preventStandby")
    UIManager:preventStandby()
end

function AutoSuspend:allowStandby()
    logger.dbg("AutoSuspend: allowStandby")
    UIManager:allowStandby()
    self.is_standby_scheduled = false
end

function AutoSuspend:onSuspend()
    logger.dbg("AutoSuspend: onSuspend")
    self:_unschedule()
    self:_unschedule_kindle()
    self:_unschedule_standby()
    if self:_enabledShutdown() and Device.wakeup_mgr then
        Device.wakeup_mgr:addTask(self.autoshutdown_timeout_seconds, UIManager.poweroff_action)
    end

    if self:_enabledStandby() and not self.going_to_suspend then
        UIManager:preventStandby()
    end

    self.going_to_suspend = true
end

function AutoSuspend:onResume()
    logger.dbg("AutoSuspend: onResume")

    if self:_enabledStandby() and self.going_to_suspend then
        UIManager:allowStandby()
    end
    self.going_to_suspend = false

    if self:_enabledShutdown() and Device.wakeup_mgr then
        Device.wakeup_mgr:removeTasks(nil, UIManager.poweroff_action)
    end
    self:_unschedule()
    self:_start()
    self:_start_kindle()
    self:_unschedule_standby()
    self:_start_standby(default_standby_timeout_after_resume_seconds)
end

function AutoSuspend:onUnexpectedWakeupLimit()
    logger.dbg("AutoSuspend: onUnexpectedWakeupLimit")
    self:_unschedule()
    self:_restart()
end

function AutoSuspend:onNotCharging()
    logger.dbg("AutoSuspend: onNotCharging")
    self:_unschedule()
    self:_start()
end

function AutoSuspend:pickTimeoutValue(touchmenu_instance, title, info, setting,
        default_value, range, time_scale)

    local InfoMessage = require("ui/widget/infomessage")
    local DateTimeWidget = require("ui/widget/datetimewidget")

    local setting_val = self[setting] > 0 and self[setting] or default_value
    local is_standby = setting == "auto_standby_timeout_seconds"

    local day, hour, minute, second
    local day_max, day_min, hour_max, min_max, sec_max
    if time_scale == 2 then
        day = math.floor(setting_val * (1/(24*3600)))
        hour = math.floor(setting_val * (1/3600)) % 24
        day_max = math.floor(range[2] * (1/(24*3600))) - 1
        day_min = 0
        hour_max = 23
    elseif time_scale == 1 then
        hour = math.floor(setting_val * (1/3600))
        minute = math.floor(setting_val * (1/60)) % 60
        hour_max = math.floor(range[2] * (1/3600)) - 1
        min_max = 59
    else
        minute = math.floor(setting_val * (1/60))
        second = math.floor(setting_val) % 60
        min_max =  math.floor(range[2] * (1/60)) - 1
        sec_max = 59
    end

    local time_spinner
    time_spinner = DateTimeWidget:new {
        day = day,
        hour = hour,
        min = minute,
        sec = second,
        day_hold_step = 5,
        hour_hold_step = 5,
        min_hold_step = 10,
        sec_hold_step = 10,
        day_max = day_max,
        day_min = day_min,
        hour_max = hour_max,
        min_max = min_max,
        sec_max = sec_max,
        ok_text = _("Set timeout"),
        title_text = title,
        info_text = info,
        callback = function(t)
            self[setting] = (((t.day or 0) * 24 +
                             (t.hour or 0)) * 60 +
                             (t.min or 0)) * 60 +
                             (t.sec or 0)
            self[setting] = Math.clamp(self[setting], range[1], range[2])
            G_reader_settings:saveSetting(setting, self[setting])
            if is_standby then
                self:_unschedule_standby()
                self:toggleStandbyHandler(self:_enabledStandby())
                self:_start_standby()
            else
                self:_unschedule()
                self:_start()
                if Device:isKindle() and setting == "auto_suspend_timeout_seconds" then
                    self:_unschedule_kindle()
                    self:_start_kindle()
                end
            end
            if touchmenu_instance then touchmenu_instance:updateItems() end
            local time_string = datetime.secondsToClockDuration("letters", self[setting],
                time_scale == 2 or time_scale == 1, true)
            UIManager:show(InfoMessage:new{
                text = T(_("%1: %2"), title, time_string),
                timeout = 3,
            })
            time_spinner:onClose()
        end,
        default_value = datetime.secondsToClockDuration("letters", default_value,
            time_scale == 2 or time_scale == 1, true),
        default_callback = function()
            local day, hour, min, sec -- luacheck: ignore 431
            if time_scale == 2 then
                day = math.floor(default_value * (1/(24*3600)))
                hour = math.floor(default_value * (1/3600)) % 24
            elseif time_scale == 1 then
                hour = math.floor(default_value * (1/3600))
                min = math.floor(default_value * (1/60)) % 60
            else
                min = math.floor(default_value * (1/60))
                sec = math.floor(default_value % 60)
            end
            time_spinner:update(nil, nil, day, hour, min, sec)
        end,
        extra_text = _("Disable"),
        extra_callback = function(this)
            self[setting] = -1 
            G_reader_settings:saveSetting(setting, -1)
            if is_standby then
                self:_unschedule_standby()
                self:toggleStandbyHandler(false)
            else
                self:_unschedule()
                if Device:isKindle() and setting == "auto_suspend_timeout_seconds" then
                    self:_unschedule_kindle()
                    self:_start_kindle()
                end
            end
            if touchmenu_instance then touchmenu_instance:updateItems() end
            UIManager:show(InfoMessage:new{
                text = T(_("%1: disabled"), title),
                timeout = 3,
            })
            this:onClose()
        end,
        keep_shown_on_apply = true,
    }
    UIManager:show(time_spinner)
end

function AutoSuspend:addToMainMenu(menu_items)
    menu_items.autosuspend = {
        sorting_hint = "device",
        checked_func = function()
            return self:_enabled()
        end,
        text_func = function()
            if self.auto_suspend_timeout_seconds and self.auto_suspend_timeout_seconds > 0 then
                local time_string = datetime.secondsToClockDuration("letters",
                    self.auto_suspend_timeout_seconds, true, true)
                return T(_("Autosuspend timeout: %1"), time_string)
            else
                return _("Autosuspend timeout")
            end
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:pickTimeoutValue(touchmenu_instance,
                _("Timeout for autosuspend"), _("Enter time in hours and minutes."),
                "auto_suspend_timeout_seconds", default_auto_suspend_timeout_seconds,
                {60, 24*3600}, 1)
        end,
    }
    if Device:canPowerOff() then
        menu_items.autoshutdown = {
            sorting_hint = "device",
            checked_func = function()
                return self:_enabledShutdown()
            end,
            text_func = function()
                if self.autoshutdown_timeout_seconds and self.autoshutdown_timeout_seconds > 0 then
                    local time_string = datetime.secondsToClockDuration("letters", self.autoshutdown_timeout_seconds,
                        true, true)
                    return T(_("Autoshutdown timeout: %1"), time_string)
                else
                    return _("Autoshutdown timeout")
                end
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:pickTimeoutValue(touchmenu_instance,
                    _("Timeout for autoshutdown"), _("Enter time in days and hours."),
                    "autoshutdown_timeout_seconds", default_autoshutdown_timeout_seconds,
                    {5*60, 28*24*3600}, 2)
            end,
        }
    end
    if Device:canStandby() then
        local standby_help = _([[Standby puts the device into a power-saving state in which the screen is on and user input can be performed.

Standby can not be entered if Wi-Fi is on.

Upon user input, the device needs a certain amount of time to wake up. Generally, the newer the device, the less noticeable this delay will be, but it can be fairly aggravating on slower devices.]])
        if Device:isKobo() and not Device:hasReliableMxcWaitFor() then
            standby_help = standby_help .. "\n" ..
                           _([[Your device is known to be extremely unreliable, as such, failure to enter a power-saving state *may* hang the kernel, resulting in a full device hang or a device restart.]])
        end

        menu_items.autostandby = {
            sorting_hint = "device",
            checked_func = function()
                return self:_enabledStandby()
            end,
            text_func = function()
                if self.auto_standby_timeout_seconds and self.auto_standby_timeout_seconds > 0 then
                    local time_string = datetime.secondsToClockDuration("letters", self.auto_standby_timeout_seconds,
                        false, true, true)
                    return T(_("Autostandby timeout: %1"), time_string)
                else
                    return _("Autostandby timeout")
                end
            end,
            help_text = standby_help,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:pickTimeoutValue(touchmenu_instance,
                    _("Timeout for autostandby"), _("Enter time in minutes and seconds."),
                    "auto_standby_timeout_seconds", default_auto_standby_timeout_seconds,
                    {1, 15*60}, 0)
            end,
        }
    end
end

function AutoSuspend:AllowStandbyHandler()
    logger.dbg("AutoSuspend: onAllowStandby")

    local wake_in
    local next_task_time = UIManager:getNextTaskTime()
    if next_task_time then
        wake_in = math.floor(time.to_number(next_task_time)) + 1
    else
        wake_in = math.huge
    end

    if wake_in >= 1 then 
        logger.dbg("AutoSuspend: entering standby with a wakeup alarm in", wake_in, "s")
        Device:standby(wake_in)
        logger.dbg("AutoSuspend: left standby after", time.format_time(Device.last_standby_time), "s")
        UIManager:shiftScheduledTasksBy( - Device.last_standby_time) 
        UIManager:consumeInputEarlyAfterPM(true)
        self:_start_standby() 
    else
        self:_start_standby(wake_in + 0.1) 
    end
end

function AutoSuspend:toggleStandbyHandler(toggle)
    if toggle then
        self.onAllowStandby = self.AllowStandbyHandler
    else
        self.onAllowStandby = nil
    end
end

function AutoSuspend:onNetworkConnected()
    logger.dbg("AutoSuspend: onNetworkConnected")
    self:_unschedule_standby()
    self:_start_standby(math.huge)
end

function AutoSuspend:onNetworkConnecting()
    logger.dbg("AutoSuspend: onNetworkConnecting")
    self:_unschedule_standby()
    self:_start_standby(time.s(60))
end

function AutoSuspend:onNetworkDisconnected()
    logger.dbg("AutoSuspend: onNetworkDisconnected")
    self:_unschedule_standby()
    self:_start_standby()
end

return AutoSuspend