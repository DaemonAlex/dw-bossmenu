local QBCore = exports['qb-core']:GetCoreObject()
local bankingModule = exports['qb-banking']

-- Global tables for data storage
local PlayerSettings = {}
local ActivityData = {}
local PlayerJoinTimes = {} -- Table to store player join times
local RefreshTimers = {}
local PlaytimeCache = {}
local SocietyTransactions = {}
local JobPermissionsCache = {}

RegisterNetEvent('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    local citizenid = Player.PlayerData.citizenid
    local jobName = Player.PlayerData.job.name
    
    PlayerJoinTimes[citizenid] = {
        time = os.time(),
        job = jobName
    }
end)


function GetCachedPlaytime(citizenid, jobName)
    local cacheKey = citizenid .. "-" .. jobName
    
    if PlaytimeCache[cacheKey] then
        return PlaytimeCache[cacheKey]
    end
    
    local dbPlaytime = MySQL.Sync.fetchScalar('SELECT total_minutes FROM job_playtime WHERE citizenid = ? AND job = ?', 
        {citizenid, jobName})
    
    if dbPlaytime then
        PlaytimeCache[cacheKey] = dbPlaytime
    end
    
    return dbPlaytime or 0
end


-- Initialize activity tracking
function InitializeActivityTracking()
    -- Reset activity data for all jobs
    for jobName, _ in pairs(QBCore.Shared.Jobs) do
        ActivityData[jobName] = {}
        for i = 0, 23 do
            ActivityData[jobName][i] = 0
        end
    end
    
    -- Start hourly tracking
    CreateThread(function()
        while true do
            local currentHour = tonumber(os.date('%H'))
            local players = QBCore.Functions.GetQBPlayers()
            
            -- Reset current hour values
            for jobName, _ in pairs(QBCore.Shared.Jobs) do
                ActivityData[jobName][currentHour] = 0
            end
            
            for _, player in pairs(players) do
                local jobName = player.PlayerData.job.name
                if ActivityData[jobName] then
                    ActivityData[jobName][currentHour] = (ActivityData[jobName][currentHour] or 0) + 1
                end
            end
            
            Wait(60000) -- Check every minute
        end
    end)
end

-- Get job data
QBCore.Functions.CreateCallback('dw-bossmenu:server:GetJobData', function(source, cb, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player or Player.PlayerData.job.name ~= jobName then
        cb(false)
        return
    end
    
    -- Check permissions - either boss or has specific permissions
    local hasBossAccess = Player.PlayerData.job.isboss
    local permissions = nil
    
    if not hasBossAccess then
        -- Get permissions from database
        local result = MySQL.Sync.fetchSingle('SELECT permissions FROM job_employee_permissions WHERE citizenid = @citizenid AND job = @job', {
            ['@citizenid'] = Player.PlayerData.citizenid,
            ['@job'] = jobName
        })
        
        if result and result.permissions then
            permissions = json.decode(result.permissions)
            
            -- Check if any permission is granted
            local hasAnyPermission = false
            for _, permValue in pairs(permissions) do
                if permValue then
                    hasAnyPermission = true
                    break
                end
            end
            
            if not hasAnyPermission then
                cb(false)
                return
            end
        else
            cb(false)
            return
        end
    end
    
    local jobLabel = QBCore.Shared.Jobs[jobName].label
    local jobGrades = QBCore.Shared.Jobs[jobName].grades
    
    -- First, collect all online players with this job to ensure immediate updates
    local onlineEmployeesList = {}
    local players = QBCore.Functions.GetQBPlayers()
    
    -- Track online players with this job first
    for _, p in pairs(players) do
        if p.PlayerData.job.name == jobName then
            onlineEmployeesList[p.PlayerData.citizenid] = true
        end
    end
    
    -- Get database records for all employees of this job
    MySQL.Async.fetchAll('SELECT citizenid, name, job, charinfo, last_updated FROM players WHERE JSON_EXTRACT(job, "$.name") = @jobName', {
        ['@jobName'] = jobName
    }, function(employees)
        local employeeData = {}
        local processedCitizenIds = {}
        
        -- Process employees from database
        for _, employee in pairs(employees) do
            local jobInfo = json.decode(employee.job)
            local gradeLevel = jobInfo.grade.level
            local gradeName = jobInfo.grade.name
            
            -- Parse charinfo if it exists
            local firstName = "Unknown"
            local lastName = "Unknown"
            local fullName = employee.name -- Fallback to Steam name
            
            if employee.charinfo then
                local charInfo = json.decode(employee.charinfo)
                if charInfo then
                    firstName = charInfo.firstname or "Unknown"
                    lastName = charInfo.lastname or "Unknown"
                    fullName = firstName .. ' ' .. lastName
                end
            end
            
            -- Check if player is online
            local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(employee.citizenid)
            local isOnline = targetPlayer ~= nil
            local location = "Offline"
            local playTime = 0
            
            if isOnline then
                location = "Online"
                
                -- If player is online, we can get their character info directly
                if targetPlayer.PlayerData.charinfo then
                    firstName = targetPlayer.PlayerData.charinfo.firstname or firstName
                    lastName = targetPlayer.PlayerData.charinfo.lastname or lastName
                    fullName = firstName .. ' ' .. lastName
                end
                
                -- Calculate playtime from PlayerJoinTimes first
                if PlayerJoinTimes[employee.citizenid] then
                    local sessionTime = math.floor((os.time() - PlayerJoinTimes[employee.citizenid].time) / 60)
                    
                    -- Get accumulated time from database - use synchronous version
                    local dbPlaytime = MySQL.Sync.fetchScalar('SELECT total_minutes FROM job_playtime WHERE citizenid = ? AND job = ?', 
                        {employee.citizenid, jobName})
                    
                    local totalPlaytime = (dbPlaytime or 0) + sessionTime
                    
                    -- Log calculation
                    
                    for i, emp in ipairs(employeeData) do
                        if emp.citizenid == employee.citizenid then
                            emp.playTime = totalPlaytime
                            break
                        end
                    end
                    
                    -- Use total time
                    playTime = totalPlaytime
                else 
                    -- If no record in PlayerJoinTimes, use metadata
                    local joinTime = targetPlayer.PlayerData.metadata.joinTime or os.time()
                    playTime = math.floor((os.time() - joinTime) / 60)
                    
                    -- Create new tracking record
                    PlayerJoinTimes[employee.citizenid] = {
                        time = joinTime,
                        job = jobName
                    }
                    
                end
            else
                -- For offline players, get playtime from database only
                local dbPlaytime = MySQL.Sync.fetchScalar('SELECT total_minutes FROM job_playtime WHERE citizenid = ? AND job = ?', 
                    {employee.citizenid, jobName})
                
                if dbPlaytime then
                    for i, emp in ipairs(employeeData) do
                        if emp.citizenid == employee.citizenid then
                            emp.playTime = dbPlaytime
                            break
                        end
                    end
                    
                    playTime = dbPlaytime
                    
                end
            end
            
            -- Management flag
            local isManagement = jobInfo.isboss or false
            
            employeeData[#employeeData+1] = {
                citizenid = employee.citizenid,
                name = fullName, -- Use the full name instead of Steam name
                grade = gradeLevel,
                gradeName = gradeName,
                isOnline = isOnline,
                isManagement = isManagement,
                location = location,
                playTime = playTime,
                lastUpdated = employee.last_updated
            }
            
            -- Mark this citizen ID as processed
            processedCitizenIds[employee.citizenid] = true
        end
        
        -- Check for any online players with this job who aren't in the database results yet
        -- This handles newly assigned jobs before database updates
        for _, p in pairs(players) do
            if p.PlayerData.job.name == jobName and not processedCitizenIds[p.PlayerData.citizenid] then
                -- This player has the job but wasn't in our database results - likely just assigned
                local firstName = "Unknown"
                local lastName = "Unknown"
                
                if p.PlayerData.charinfo then
                    firstName = p.PlayerData.charinfo.firstname or "Unknown"
                    lastName = p.PlayerData.charinfo.lastname or "Unknown"
                end
                
                local fullName = firstName .. ' ' .. lastName
                local playTime = 0
                
                -- Check for join time tracking
                if PlayerJoinTimes[p.PlayerData.citizenid] then
                    local sessionTime = math.floor((os.time() - PlayerJoinTimes[p.PlayerData.citizenid].time) / 60)
                    local dbPlaytime = MySQL.Sync.fetchScalar('SELECT total_minutes FROM job_playtime WHERE citizenid = ? AND job = ?', 
                        {p.PlayerData.citizenid, jobName}) or 0
                    
                    playTime = dbPlaytime + sessionTime
                else
                    -- Initialize tracking
                    PlayerJoinTimes[p.PlayerData.citizenid] = {
                        time = os.time(),
                        job = jobName
                    }
                end
                -- newly found employee to our list
                employeeData[#employeeData+1] = {
                    citizenid = p.PlayerData.citizenid,
                    name = fullName,
                    grade = tonumber(p.PlayerData.job.grade.level),
                    gradeName = p.PlayerData.job.grade.name,
                    isOnline = true,
                    isManagement = p.PlayerData.job.isboss or false,
                    location = "Online",
                    playTime = playTime,
                    lastUpdated = os.date()
                }  
            end
        end
            
        -- Count online employees for activity tracking
        local onlineCount = 0
        for _, employee in pairs(employeeData) do
            if employee.isOnline then
                onlineCount = onlineCount + 1
            end
        end
        
        -- Create activity data from monitored data
        local activityData = {}
        for i = 0, 23 do
            local hour = i
            local count = ActivityData[jobName] and ActivityData[jobName][hour] or 0
            activityData[#activityData+1] = {
                hour = hour,
                count = count
            }
        end
        
        -- Weekly playtime summary (mock calculation)
        local weeklyPlaytime = 0
        local onlineEmployees = 0
        
        for _, employee in pairs(employeeData) do
            if employee.isOnline then
                weeklyPlaytime = weeklyPlaytime + employee.playTime
                onlineEmployees = onlineEmployees + 1
            end
        end
        
        -- Calculate average working hours
        local averagePlaytime = onlineEmployees > 0 and math.floor(weeklyPlaytime / onlineEmployees) or 0
        
        -- Build final data structure
        local jobData = {
            jobName = jobName,
            jobLabel = jobLabel,
            employees = employeeData,
            onlineCount = onlineCount,
            totalEmployees = #employeeData,
            activityData = activityData,
            grades = jobGrades,
            weeklyPlaytime = weeklyPlaytime,
            averagePlaytime = averagePlaytime,
            permissions = permissions  -- Add permissions to the response
        }
        
        -- Save refresh data for player
        if not RefreshTimers[src] then
            StartRefreshTimer(src, jobName)
        end
        societyData = GetSocietyData(jobName)
        jobData.societyData = societyData
        cb(jobData)
    end)
end)

-- Create automatic refresh timer for player
function StartRefreshTimer(src, jobName)
    -- Clear existing timer if any
    if RefreshTimers[src] then
        ClearTimeout(RefreshTimers[src])
        RefreshTimers[src] = nil
    end
    
    -- Create new timer with minimum interval
    local interval = math.max((PlayerSettings[src] and PlayerSettings[src].refreshInterval or 60), 30) * 1000
    
    RefreshTimers[src] = SetTimeout(interval, function()
        local Player = QBCore.Functions.GetPlayer(src)
        if Player and Player.PlayerData.job.name == jobName then
            -- Send auto-refresh event to client
            TriggerClientEvent('dw-bossmenu:client:RefreshData', src)
            
            -- Restart timer
            StartRefreshTimer(src, jobName)
        else
            -- If player disconnected or changed jobs, clear timer
            RefreshTimers[src] = nil
        end
    end)
end

-- Get user settings
QBCore.Functions.CreateCallback('dw-bossmenu:server:GetSettings', function(source, cb)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player then
        cb(Config.DefaultSettings)
        return
    end
    
    -- Check if settings exist
    local citizenid = Player.PlayerData.citizenid
    
    MySQL.Async.fetchAll('SELECT settings FROM job_manager_settings WHERE citizenid = @citizenid', {
        ['@citizenid'] = citizenid
    }, function(result)
        if result and result[1] and result[1].settings then
            local settings = json.decode(result[1].settings)
            PlayerSettings[src] = settings
            cb(settings)
        else
            -- Use default settings
            PlayerSettings[src] = Config.DefaultSettings
            cb(Config.DefaultSettings)
        end
    end)
end)

RegisterNetEvent('dw-bossmenu:server:UpdateEmployee', function(citizenid, jobName, grade)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player or Player.PlayerData.job.name ~= jobName then
        TriggerClientEvent('QBCore:Notify', src, "You don't have permission for this action", "error")
        return
    end
    
    -- Check if player has boss permissions
    if not Player.PlayerData.job.isboss then
        TriggerClientEvent('QBCore:Notify', src, "You don't have permission for this action", "error")
        return
    end
    
    -- Check if employee exists
    local targetExists = false
    MySQL.Async.fetchSingle('SELECT 1 FROM players WHERE citizenid = @citizenid', {
        ['@citizenid'] = citizenid
    }, function(result)
        if not result then
            TriggerClientEvent('QBCore:Notify', src, "Player not found", "error")
            return
        end
if type(grade) == 'number' then
    grade = tostring(grade)
end


if not QBCore.Shared.Jobs[jobName].grades[grade] then
    TriggerClientEvent('QBCore:Notify', src, "Invalid job grade", "error")
    return
end
        if not QBCore.Shared.Jobs[jobName].grades[grade] then
            TriggerClientEvent('QBCore:Notify', src, "Invalid job grade", "error")
            return
        end
        
        local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(citizenid)
        if targetPlayer then
            -- Verify employee is already in this job or updating job itself
            local targetCurrentJob = targetPlayer.PlayerData.job.name
            
            if targetCurrentJob == jobName then
                -- Only update grade
                targetPlayer.Functions.SetJobDuty(true)
                targetPlayer.Functions.SetJob(jobName, grade)
                TriggerClientEvent('QBCore:Notify', targetPlayer.PlayerData.source, "Your rank has been updated to " .. QBCore.Shared.Jobs[jobName].grades[grade].name, "success")
                TriggerClientEvent('QBCore:Notify', src, "Employee rank updated successfully", "success")
                
                -- Log entry
                TriggerEvent('qb-log:server:CreateLog', 'jobmanagement', 'Employee Rank Update', 'green', string.format('%s (%s) updated %s (%s) to rank %s in job %s', 
                    GetPlayerName(src), Player.PlayerData.citizenid, GetPlayerName(targetPlayer.PlayerData.source), citizenid, grade, jobName))
            else
                targetPlayer.Functions.SetJob(jobName, grade)
                TriggerClientEvent('dw-bossmenu:client:JobChanged', -1, jobName)
                TriggerClientEvent('QBCore:Notify', targetPlayer.PlayerData.source, "Your job has been changed to " .. QBCore.Shared.Jobs[jobName].label, "success")
                TriggerClientEvent('QBCore:Notify', src, "Employee successfully transferred to this job", "success")
                
                -- Log entry
                TriggerEvent('qb-log:server:CreateLog', 'jobmanagement', 'Job Change', 'green', string.format('%s (%s) changed %s (%s) job from %s to %s at rank %s', 
                    GetPlayerName(src), Player.PlayerData.citizenid, GetPlayerName(targetPlayer.PlayerData.source), citizenid, targetCurrentJob, jobName, grade))
            end
        else
            -- First check current job
            MySQL.Async.fetchSingle('SELECT job FROM players WHERE citizenid = @citizenid', {
                ['@citizenid'] = citizenid
            }, function(result)
                if not result or not result.job then
                    TriggerClientEvent('QBCore:Notify', src, "Error updating employee", "error")
                    return
                end
                
                local currentJob = json.decode(result.job)
                local jobInfo = {
                    name = jobName,
                    label = QBCore.Shared.Jobs[jobName].label,
                    payment = QBCore.Shared.Jobs[jobName].grades[grade].payment,
                    onduty = true,
                    grade = {
                        level = grade,
                        name = QBCore.Shared.Jobs[jobName].grades[grade].name
                    },
                    isboss = QBCore.Shared.Jobs[jobName].grades[grade].isboss or false
                }
                
                MySQL.Async.execute('UPDATE players SET job = @job WHERE citizenid = @citizenid', {
                    ['@citizenid'] = citizenid,
                    ['@job'] = json.encode(jobInfo)
                }, function(rowsChanged)
                    if rowsChanged > 0 then
                        if currentJob.name == jobName then
                            TriggerClientEvent('QBCore:Notify', src, "Employee rank updated successfully", "success")
                        else
                            TriggerClientEvent('QBCore:Notify', src, "Employee successfully transferred to this job", "success")
                        end
                        
                        -- Log entry
                        TriggerEvent('qb-log:server:CreateLog', 'jobmanagement', 'Offline Employee Update', 'green', string.format('%s (%s) updated %s job from %s to %s at rank %s', 
                            GetPlayerName(src), Player.PlayerData.citizenid, citizenid, currentJob.name, jobName, grade))
                    else
                        TriggerClientEvent('QBCore:Notify', src, "Update failed", "error")
                    end
                end)
            end)
        end
    end)
end)

-- Hire new employee
RegisterNetEvent('dw-bossmenu:server:HireEmployee', function(targetId, jobName, grade)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local Target = QBCore.Functions.GetPlayer(tonumber(targetId))
    
    if not Player or not Target then
        TriggerClientEvent('QBCore:Notify', src, "Player not found", "error")
        return
    end
    
    if Player.PlayerData.job.name ~= jobName then
        TriggerClientEvent('QBCore:Notify', src, "You don't have permission for this action", "error")
        return
    end
    
    -- Check if player has boss permissions
    if not Player.PlayerData.job.isboss then
        TriggerClientEvent('QBCore:Notify', src, "You don't have permission for this action", "error")
        return
    end
    
    -- Check if grade exists for this job
    if not QBCore.Shared.Jobs[jobName].grades[grade] then
        TriggerClientEvent('QBCore:Notify', src, "Invalid job grade", "error")
        return
    end
    
    --  target job
    Target.Functions.SetJob(jobName, grade)
    
    TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, "You've been hired: " .. QBCore.Shared.Jobs[jobName].label, "success")
    TriggerClientEvent('QBCore:Notify', src, "Player successfully hired", "success")
    TriggerClientEvent('dw-bossmenu:client:JobChanged', -1, jobName)
    TriggerEvent('qb-log:server:CreateLog', 'jobmanagement', 'Employee Hire', 'green', string.format('%s (%s) hired %s (%s) for job %s at rank %s', 
        GetPlayerName(src), Player.PlayerData.citizenid, GetPlayerName(Target.PlayerData.source), Target.PlayerData.citizenid, jobName, grade))
end)

-- Remove employee from job
RegisterNetEvent('dw-bossmenu:server:RemoveEmployee', function(citizenid, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player or Player.PlayerData.job.name ~= jobName then
        TriggerClientEvent('QBCore:Notify', src, "You don't have permission for this action", "error")
        return
    end
    
    -- Check if player has boss permissions
    if not Player.PlayerData.job.isboss then
        TriggerClientEvent('QBCore:Notify', src, "You don't have permission for this action", "error")
        return
    end
    
    -- Check if employee exists and belongs to this job
    MySQL.Async.fetchSingle('SELECT job FROM players WHERE citizenid = @citizenid', {
        ['@citizenid'] = citizenid
    }, function(result)
        if not result or not result.job then
            TriggerClientEvent('QBCore:Notify', src, "Player not found", "error")
            return
        end
        
        local currentJob = json.decode(result.job)
        if currentJob.name ~= jobName then
            TriggerClientEvent('QBCore:Notify', src, "This player doesn't work for this job", "error")
            return
        end
        
        -- Set default job for online player
        local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(citizenid)
        if targetPlayer then
            targetPlayer.Functions.SetJob("unemployed", 0)
            TriggerClientEvent('QBCore:Notify', targetPlayer.PlayerData.source, "You have been fired from your job", "error")
            TriggerClientEvent('QBCore:Notify', src, "Employee removed successfully", "success")
            
            -- Log entry
            TriggerEvent('qb-log:server:CreateLog', 'jobmanagement', 'Employee Fired', 'red', string.format('%s (%s) fired %s (%s) from job %s', 
                GetPlayerName(src), Player.PlayerData.citizenid, GetPlayerName(targetPlayer.PlayerData.source), citizenid, jobName))
        else
            local jobInfo = {
                name = "unemployed",
                label = "Unemployed",
                payment = 10,
                onduty = true,
                grade = {
                    level = 0,
                    name = "Unemployed"
                },
                isboss = false
            }
            
            MySQL.Async.execute('UPDATE players SET job = @job WHERE citizenid = @citizenid', {
                ['@citizenid'] = citizenid,
                ['@job'] = json.encode(jobInfo)
            }, function(rowsChanged)
                if rowsChanged > 0 then
                    TriggerClientEvent('QBCore:Notify', src, "Employee removed successfully", "success")
                    
                    -- Log entry
                    TriggerEvent('qb-log:server:CreateLog', 'jobmanagement', 'Offline Employee Fired', 'red', string.format('%s (%s) fired %s from job %s', 
                        GetPlayerName(src), Player.PlayerData.citizenid, citizenid, jobName))
                        TriggerClientEvent('dw-bossmenu:client:JobChanged', -1, jobName)
                else
                    TriggerClientEvent('QBCore:Notify', src, "Removal failed", "error")
                end
            end)
        end
    end)
end)

-- Save user settings
RegisterNetEvent('dw-bossmenu:server:SaveSettings', function(settings)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player then return end
    
    local citizenid = Player.PlayerData.citizenid
    
    PlayerSettings[src] = settings
    
    if settings.refreshInterval and RefreshTimers[src] then
        ClearTimeout(RefreshTimers[src])
        RefreshTimers[src] = nil
        StartRefreshTimer(src, Player.PlayerData.job.name)
    end
    
    -- Save settings to database
    MySQL.Async.execute('INSERT INTO job_manager_settings (citizenid, settings) VALUES (@citizenid, @settings) ON DUPLICATE KEY UPDATE settings = @settings', {
        ['@citizenid'] = citizenid,
        ['@settings'] = json.encode(settings)
    }, function(rowsChanged)
        if rowsChanged > 0 then
            TriggerClientEvent('QBCore:Notify', src, "Settings saved successfully", "success")
        else
            TriggerClientEvent('QBCore:Notify', src, "Error saving settings", "error")
        end
    end)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end    
    for citizenid, _ in pairs(PlayerJoinTimes) do
        UpdatePlayerPlaytime(citizenid)
    end
end)

-- Clear timers when player disconnects
AddEventHandler('playerDropped', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if Player then
        UpdatePlayerPlaytime(Player.PlayerData.citizenid)
    end
end)

function UpdatePlayerPlaytime(citizenid)
    local joinData = PlayerJoinTimes[citizenid]
    if not joinData then return end
    
    local currentTime = os.time()
    local sessionTime = currentTime - joinData.time
    local sessionMinutes = math.floor(sessionTime / 60)
    
    if sessionMinutes <= 0 then return end
    
    local jobName = joinData.job  
    
    if PlaytimeCache then  
        local cacheKey = citizenid .. "-" .. jobName
        if PlaytimeCache[cacheKey] then
            PlaytimeCache[cacheKey] = PlaytimeCache[cacheKey] + sessionMinutes
        else
            PlaytimeCache[cacheKey] = sessionMinutes
        end
    end
    
    MySQL.Async.execute('INSERT INTO job_playtime (citizenid, job, total_minutes) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE total_minutes = total_minutes + ?', 
        {citizenid, jobName, sessionMinutes, sessionMinutes}, 
        function(rowsChanged)
            if PlayerJoinTimes[citizenid] then
                PlayerJoinTimes[citizenid].time = currentTime
            end
        end
    )
end


RegisterNetEvent('QBCore:Server:OnJobUpdate', function(source, newJob)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if Player then
        UpdatePlayerPlaytime(Player.PlayerData.citizenid)
        
        -- Start tracking for new job (existing code)
        PlayerJoinTimes[Player.PlayerData.citizenid] = {
            time = os.time(),
            job = newJob.name
        }
        
        -- NEW: Notify all boss menu clients to refresh their data for this job
        TriggerClientEvent('dw-bossmenu:client:JobChanged', -1, newJob.name)
    end
end)

-- Add chat command for quick management (optional)
QBCore.Commands.Add('managejob', 'Open job management interface', {}, false, function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    
    local jobName = Player.PlayerData.job.name
    
    -- Check if player has management permissions
    if not Player.PlayerData.job.isboss then
        TriggerClientEvent('QBCore:Notify', source, "You don't have permission to manage this job", "error")
        return
    end
    
    TriggerClientEvent('dw-bossmenu:client:TriggerOpenManager', source, {jobData = jobName})
end)

RegisterNetEvent('dw-bossmenu:server:RefreshPlayTime', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player then return end
    
    if Player.PlayerData.job.isboss then
        TriggerClientEvent('dw-bossmenu:client:RefreshData', src)
    end
end)

function LoadSocietyTransactions()
    local result = MySQL.Sync.fetchAll('SELECT * FROM society_transactions ORDER BY timestamp DESC LIMIT 1000')
    
    if result and #result > 0 then
        SocietyTransactions = {}
        
        for _, transaction in ipairs(result) do
            local societyName = transaction.society
            
            if not SocietyTransactions[societyName] then
                SocietyTransactions[societyName] = {}
            end
            
            table.insert(SocietyTransactions[societyName], {
                type = transaction.type,
                amount = transaction.amount,
                employee = transaction.employee,
                executor = transaction.executor,
                note = transaction.note,
                timestamp = transaction.timestamp
            })
        end
        
        for societyName, transactions in pairs(SocietyTransactions) do
            table.sort(transactions, function(a, b)
                return a.timestamp > b.timestamp
            end)
            
            if #transactions > 50 then
                local newTransactions = {}
                for i = 1, 50 do
                    newTransactions[i] = transactions[i]
                end
                SocietyTransactions[societyName] = newTransactions
            end
        end
    else
        print("^2[dw-bossmenu]^7 No society transactions found in database")
    end
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    Wait(1000) 
    InitializeActivityTracking()
    LoadSocietyTransactions()
    TriggerEvent('QBCore:server:UpdateObject')
    if resource == GetCurrentResourceName() then
        -- רענן את qb-banking כשהסקריפט מתחיל
        if Config.BankingSystem == "qb-banking" then
            TriggerEvent('qb-banking:server:RefreshAccounts')
        end
    end
end)

function GetSocietyData(jobName)
    if not jobName then return nil end
    
    local societyName = jobName
    local result = nil
    local balance = 0
    
    if Config.BankingSystem == "dw-banking" then
        -- Original method for dw-banking
        result = MySQL.Sync.fetchSingle('SELECT * FROM society WHERE name = ?', {societyName})
        
        if not result then
            MySQL.Sync.execute('INSERT INTO society (name, money) VALUES (?, ?)', {societyName, 0})
            result = {name = societyName, money = 0}
        end
        
        balance = result.money
    elseif Config.BankingSystem == "qb-banking" then
        -- קודם ננסה לקבל את היתרה דרך האקספורט של qb-banking
        local account = bankingModule:GetAccount(societyName)
        
        if account then
            balance = account.account_balance
        else
            -- אם לא מצאנו בזיכרון, ננסה לקבל מהדאטהבייס
            result = MySQL.Sync.fetchSingle('SELECT * FROM bank_accounts WHERE account_name = ?', {societyName})
            
            if not result then
                -- אם לא קיים, נייצר חשבון חדש
                bankingModule:CreateJobAccount(societyName, 0)
                balance = 0
            else
                balance = result.account_balance
            end
        end
    end
    
    if not SocietyTransactions[societyName] then
        SocietyTransactions[societyName] = {}
        
        local transactions = MySQL.Sync.fetchAll('SELECT * FROM society_transactions WHERE society = ? ORDER BY timestamp DESC LIMIT 50', {societyName})
        if transactions and #transactions > 0 then
            for _, transaction in ipairs(transactions) do
                table.insert(SocietyTransactions[societyName], {
                    type = transaction.type,
                    amount = transaction.amount,
                    employee = transaction.employee,
                    executor = transaction.executor,
                    note = transaction.note,
                    timestamp = transaction.timestamp
                })
            end
        end
    end
    
    -- Return data in a standardized format
    return {
        name = jobName,
        balance = balance,
        transactions = SocietyTransactions[societyName] or {}
    }
end


function AddSocietyTransaction(societyName, transactionData)
    if not SocietyTransactions[societyName] then
        SocietyTransactions[societyName] = {}
    end
    
    transactionData.timestamp = os.time()
    
    table.insert(SocietyTransactions[societyName], 1, transactionData)
    
    if #SocietyTransactions[societyName] > 50 then
        table.remove(SocietyTransactions[societyName], 51)
    end
    
    MySQL.Async.execute('INSERT INTO society_transactions (society, type, amount, employee, executor, note, timestamp) VALUES (?, ?, ?, ?, ?, ?, ?)', {
        societyName, 
        transactionData.type, 
        transactionData.amount, 
        transactionData.employee or '', 
        transactionData.executor or '', 
        transactionData.note or '', 
        transactionData.timestamp
    })
end

QBCore.Functions.CreateCallback('dw-bossmenu:server:GetSocietyData', function(source, cb, jobName)
    local src = source
    
    if not HasSocietyPermission(src, jobName) then
        cb(false)
        return
    end
    
    cb(GetSocietyData(jobName))
end)

-- Deposit money into society account
RegisterNetEvent('dw-bossmenu:server:DepositMoney', function(amount, note, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not HasSocietyPermission(src, jobName) then
        TriggerClientEvent('QBCore:Notify', src, "You don't have permission for this action", "error")
        return
    end
    
    if Player.PlayerData.money.cash < amount then
        TriggerClientEvent('QBCore:Notify', src, "You don't have enough cash", "error")
        return
    end
    
    Player.Functions.RemoveMoney('cash', amount)
    
    local societyName = jobName
    
    -- במקום לעדכן ישירות את הדאטהבייס, השתמש באקספורט של qb-banking
    if Config.BankingSystem == "dw-banking" then
        -- שימוש בשיטה המקורית
        MySQL.Async.execute('UPDATE society SET money = money + ? WHERE name = ?', {amount, societyName})
    elseif Config.BankingSystem == "qb-banking" then
        -- קריאה לפונקציה AddMoney של qb-banking שמעדכנת גם את הזיכרון וגם את הדאטהבייס
        local success = bankingModule:AddMoney(societyName, amount, note or "Boss Menu Deposit")
        
        if not success then
            -- אם הפונקציה נכשלה, נעדכן ישירות את הדאטהבייס ונשדר אירוע לרענון
            MySQL.Async.execute('UPDATE bank_accounts SET account_balance = account_balance + ? WHERE account_name = ?', {amount, societyName})
            TriggerEvent('qb-banking:server:RefreshAccounts')
        end
    end
    
    local playerName = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
    AddSocietyTransaction(societyName, {
        type = 'deposit',
        amount = amount,
        employee = playerName,
        note = note
    })
    
    TriggerClientEvent('QBCore:Notify', src, "Successfully deposited " .. amount .. "$ to society account", "success")
    
    TriggerEvent('qb-log:server:CreateLog', 'society', 'Society Deposit', 'green', string.format('%s (%s) deposited %s$ to %s society', 
        GetPlayerName(src), Player.PlayerData.citizenid, amount, jobName))
end)

-- Withdraw money from society account
RegisterNetEvent('dw-bossmenu:server:WithdrawMoney', function(amount, note, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not HasSocietyPermission(src, jobName) then
        TriggerClientEvent('QBCore:Notify', src, "You don't have permission for this action", "error")
        return
    end
    
    local societyName = jobName
    local currentBalance = 0
    
    -- Get current society balance based on banking system
    if Config.BankingSystem == "dw-banking" then
        local society = MySQL.Sync.fetchSingle('SELECT money FROM society WHERE name = ?', {societyName})
        if society then
            currentBalance = society.money
        end
    elseif Config.BankingSystem == "qb-banking" then
        -- השתמש בפונקציה GetAccountBalance של qb-banking
        currentBalance = bankingModule:GetAccountBalance(societyName)
        
        -- אם אין חשבון באובייקט של qb-banking, בדוק בדאטהבייס
        if currentBalance == 0 then
            local account = MySQL.Sync.fetchSingle('SELECT account_balance FROM bank_accounts WHERE account_name = ?', {societyName})
            if account then
                currentBalance = account.account_balance
            end
        end
    end
    
    if currentBalance < amount then
        TriggerClientEvent('QBCore:Notify', src, "Not enough funds in society account", "error")
        return
    end
    
    -- Update society money based on banking system
    if Config.BankingSystem == "dw-banking" then
        MySQL.Async.execute('UPDATE society SET money = money - ? WHERE name = ?', {amount, societyName})
    elseif Config.BankingSystem == "qb-banking" then
        -- קריאה לפונקציה RemoveMoney של qb-banking שמעדכנת גם את הזיכרון וגם את הדאטהבייס
        local success = bankingModule:RemoveMoney(societyName, amount, note or "Boss Menu Withdrawal")
        
        if not success then
            -- אם הפונקציה נכשלה, נעדכן ישירות את הדאטהבייס ונשדר אירוע לרענון
            MySQL.Async.execute('UPDATE bank_accounts SET account_balance = account_balance - ? WHERE account_name = ?', {amount, societyName})
            TriggerEvent('qb-banking:server:RefreshAccounts')
        end
    end
    
    Player.Functions.AddMoney('cash', amount)
    
    local playerName = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
    AddSocietyTransaction(societyName, {
        type = 'withdraw',
        amount = amount,
        employee = playerName,
        note = note
    })
    
    TriggerClientEvent('QBCore:Notify', src, "Successfully withdrawn " .. amount .. "$ from society account", "success")
    
    TriggerEvent('qb-log:server:CreateLog', 'society', 'Society Withdraw', 'red', string.format('%s (%s) withdrawn %s$ from %s society', 
        GetPlayerName(src), Player.PlayerData.citizenid, amount, jobName))
end)


-- Transfer money from society account to employee
RegisterNetEvent('dw-bossmenu:server:TransferMoney', function(citizenid, amount, note, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not HasSocietyPermission(src, jobName) then
        TriggerClientEvent('QBCore:Notify', src, "You don't have permission for this action", "error")
        return
    end
    
    local societyName = jobName
    local currentBalance = 0
    
    -- Get current society balance based on banking system
    if Config.BankingSystem == "dw-banking" then
        local society = MySQL.Sync.fetchSingle('SELECT money FROM society WHERE name = ?', {societyName})
        if society then
            currentBalance = society.money
        end
    elseif Config.BankingSystem == "qb-banking" then
        -- השתמש בפונקציה GetAccountBalance של qb-banking
        currentBalance = bankingModule:GetAccountBalance(societyName)
        
        -- אם אין חשבון באובייקט של qb-banking, בדוק בדאטהבייס
        if currentBalance == 0 then
            local account = MySQL.Sync.fetchSingle('SELECT account_balance FROM bank_accounts WHERE account_name = ?', {societyName})
            if account then
                currentBalance = account.account_balance
            end
        end
    end
    
    if currentBalance < amount then
        TriggerClientEvent('QBCore:Notify', src, "Not enough funds in society account", "error")
        return
    end
    
    local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if not targetPlayer then
        TriggerClientEvent('QBCore:Notify', src, "Employee not found or not online", "error")
        return
    end
    
    -- Update society money based on banking system
    if Config.BankingSystem == "dw-banking" then
        MySQL.Async.execute('UPDATE society SET money = money - ? WHERE name = ?', {amount, societyName})
    elseif Config.BankingSystem == "qb-banking" then
        -- קריאה לפונקציה RemoveMoney של qb-banking שמעדכנת גם את הזיכרון וגם את הדאטהבייס
        local success = bankingModule:RemoveMoney(societyName, amount, note or "Boss Menu Transfer to " .. targetPlayer.PlayerData.charinfo.firstname)
        
        if not success then
            -- אם הפונקציה נכשלה, נעדכן ישירות את הדאטהבייס ונשדר אירוע לרענון
            MySQL.Async.execute('UPDATE bank_accounts SET account_balance = account_balance - ? WHERE account_name = ?', {amount, societyName})
            TriggerEvent('qb-banking:server:RefreshAccounts')
        end
    end
    
    targetPlayer.Functions.AddMoney('bank', amount)
    
    local playerName = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
    local targetName = targetPlayer.PlayerData.charinfo.firstname .. ' ' .. targetPlayer.PlayerData.charinfo.lastname
    AddSocietyTransaction(societyName, {
        type = 'transfer',
        amount = amount,
        employee = targetName,
        executor = playerName,
        note = note
    })
    
    TriggerClientEvent('QBCore:Notify', src, "Successfully transferred " .. amount .. "$ to " .. targetName, "success")
    TriggerClientEvent('QBCore:Notify', targetPlayer.PlayerData.source, "You received " .. amount .. "$ from society account", "success")
    
    TriggerEvent('qb-log:server:CreateLog', 'society', 'Society Transfer', 'yellow', string.format('%s (%s) transferred %s$ from %s society to %s (%s)', 
        GetPlayerName(src), Player.PlayerData.citizenid, amount, jobName, GetPlayerName(targetPlayer.PlayerData.source), citizenid))
end)


-- Handle application submission
RegisterNetEvent('dw-bossmenu:server:SubmitApplication', function(jobName, answers)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player then return end
    
    local citizenid = Player.PlayerData.citizenid
    local charInfo = Player.PlayerData.charinfo
    
    -- Format full name
    local fullName = (charInfo.firstname or "Unknown") .. " " .. (charInfo.lastname or "Unknown")
    
    -- Insert into database
    MySQL.Async.execute('INSERT INTO job_applications (citizenid, job, name, answers, status) VALUES (?, ?, ?, ?, ?)', {
        citizenid,
        jobName,
        fullName,
        json.encode(answers),
        'pending'
    }, function(rowsInserted)
        if rowsInserted > 0 then
            TriggerClientEvent('QBCore:Notify', src, "Your application has been submitted successfully.", "success")
            
            -- Notify job bosses that there's a new application
            NotifyJobBosses(jobName, fullName)
        else
            TriggerClientEvent('QBCore:Notify', src, "Failed to submit application. Please try again.", "error")
        end
    end)
end)

-- Function to notify job bosses about new application
function NotifyJobBosses(jobName, applicantName)
    local players = QBCore.Functions.GetQBPlayers()
    
    for _, Player in pairs(players) do
        if Player.PlayerData.job.name == jobName and Player.PlayerData.job.isboss then
            TriggerClientEvent('QBCore:Notify', Player.PlayerData.source, "New job application received from " .. applicantName, "info")
        end
    end
end

-- Get applications for a specific job
QBCore.Functions.CreateCallback('dw-bossmenu:server:GetJobApplications', function(source, cb, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player or Player.PlayerData.job.name ~= jobName then
        cb(false)
        return
    end
    
    -- Check if player has boss permissions
    if not Player.PlayerData.job.isboss then
        cb(false)
        return
    end
    
    -- Fetch applications for this job
    MySQL.Async.fetchAll('SELECT * FROM job_applications WHERE job = ? ORDER BY date_submitted DESC', {
        jobName
    }, function(applications)
        if applications then
            -- Parse the answers JSON for each application
            for i, application in ipairs(applications) do
                application.answers = json.decode(application.answers)
            end
            
            cb(applications)
        else
            cb({})
        end
    end)
end)

RegisterNetEvent('dw-bossmenu:server:UpdateApplicationStatus', function(applicationId, status, notes)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player or not Player.PlayerData.job.isboss then
        TriggerClientEvent('QBCore:Notify', src, "You don't have permission for this action", "error")
        return
    end
    
    MySQL.Async.fetchSingle('SELECT * FROM job_applications WHERE id = ?', {
        applicationId
    }, function(application)
        if not application or application.job ~= Player.PlayerData.job.name then
            TriggerClientEvent('QBCore:Notify', src, "Invalid application", "error")
            return
        end
        
        if status ~= 'accepted' and status ~= 'rejected' and status ~= 'finish' and status ~= 'pending' then
            TriggerClientEvent('QBCore:Notify', src, "Invalid status", "error")
            return
        end
        
        MySQL.Async.execute('UPDATE job_applications SET status = ?, date_reviewed = NOW(), reviewer_id = ?, notes = ? WHERE id = ?', {
            status,
            Player.PlayerData.citizenid,
            notes or '',
            applicationId
        }, function(rowsChanged)
            if rowsChanged > 0 then
                local statusMessage = "Application status updated"
                if status == 'accepted' then
                    statusMessage = "Application accepted successfully"
                elseif status == 'rejected' then
                    statusMessage = "Application rejected successfully"
                elseif status == 'finish' then
                    statusMessage = "Application marked as finished successfully"
                end
                
                TriggerClientEvent('QBCore:Notify', src, statusMessage, "success")
                
                local targetCitizenId = application.citizenid
                local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(targetCitizenId)
                
                if targetPlayer then
                    if status == 'accepted' then
                        TriggerClientEvent('QBCore:Notify', targetPlayer.PlayerData.source, "Your job application has been accepted! Visit the workplace to start.", "success")
                    elseif status == 'rejected' then
                        TriggerClientEvent('QBCore:Notify', targetPlayer.PlayerData.source, "Your job application has been rejected.", "error")
                    elseif status == 'finish' then
                        TriggerClientEvent('QBCore:Notify', targetPlayer.PlayerData.source, "Your job application process has been completed. You can apply again if needed.", "info")
                    end
                end
            else
                TriggerClientEvent('QBCore:Notify', src, "Update failed", "error")
            end
        end)
    end)
end)

QBCore.Functions.CreateCallback('dw-bossmenu:server:CheckPendingApplication', function(source, cb, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player then
        cb(false)
        return
    end
    
    local citizenid = Player.PlayerData.citizenid
    
    MySQL.Async.fetchSingle('SELECT id, status FROM job_applications WHERE citizenid = @citizenid AND job = @jobName ORDER BY date_submitted DESC LIMIT 1', {
        ['@citizenid'] = citizenid,
        ['@jobName'] = jobName
    }, function(application)
        if not application then
            cb(false)
            return
        end
        
        if application.status == 'pending' then
            cb(true)
        elseif application.status == 'finish' then
            cb(false)
        else
            cb(true)
        end
    end)
end)

QBCore.Functions.CreateCallback('dw-bossmenu:server:CheckApplicationStatus', function(source, cb, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player then
        cb({canApply = true, message = ""})
        return
    end
    
    local citizenid = Player.PlayerData.citizenid
    
    MySQL.Async.fetchAll('SELECT status, date_reviewed FROM job_applications WHERE citizenid = @citizenid AND job = @jobName ORDER BY date_submitted DESC LIMIT 1', {
        ['@citizenid'] = citizenid,
        ['@jobName'] = jobName
    }, function(result)
        if not result or #result == 0 then
            cb({canApply = true, message = ""})
            return
        end
        
        local lastApplication = result[1]
        
        if lastApplication.status == "pending" then
            cb({canApply = false, message = "You already have a pending application for this job. Please wait for a response."})
            return
        elseif lastApplication.status == "rejected" then
            local currentTime = os.time()
            local reviewTime = lastApplication.date_reviewed ~= nil and MySQL.Sync.prepare("SELECT UNIX_TIMESTAMP(?)", {lastApplication.date_reviewed}) or 0
            local cooldownTime = 3 * 24 * 60 * 60 -- 3 days in seconds
            
            if currentTime - reviewTime < cooldownTime then
                local daysLeft = math.ceil((cooldownTime - (currentTime - reviewTime)) / (24 * 60 * 60))
                cb({canApply = false, message = "Your previous application was rejected. You can apply again in " .. daysLeft .. " day(s)."})
            else
            end
        elseif lastApplication.status == "accepted" then
            cb({canApply = false, message = "Your application has been accepted! Please contact an administrator for further instructions."})
        else
            cb({canApply = true, message = ""})
        end
    end)
end)

-- Admin command to reset the cooldown period for a specific player
QBCore.Commands.Add('resetapplicationstatus', 'Reset a player\'s application status', {{name = 'id', help = 'Player ID'}, {name = 'job', help = 'Job name (police, ambulance, etc.)'}}, true, function(source, args)
    local src = source
    local targetId = tonumber(args[1])
    local jobName = args[2]
    
    if not QBCore.Functions.HasPermission(src, 'admin') and not QBCore.Functions.HasPermission(src, 'god') then
        TriggerClientEvent('QBCore:Notify', src, 'You do not have permission to use this command', 'error')
        return
    end
    
    local target = QBCore.Functions.GetPlayer(targetId)
    if not target then
        TriggerClientEvent('QBCore:Notify', src, 'Player not found', 'error')
        return
    end
    
    -- Delete old records or update status
    MySQL.Async.execute('DELETE FROM job_applications WHERE citizenid = ? AND job = ?', {target.PlayerData.citizenid, jobName}, function()
        TriggerClientEvent('QBCore:Notify', src, 'Reset application status for ' .. target.PlayerData.name .. ' for job ' .. jobName, 'success')
        TriggerClientEvent('QBCore:Notify', targetId, 'Your application status has been reset for ' .. jobName, 'success')
    end)
end, 'admin')

-- Save changes directly to the jobs.lua file
function CompletelyRebuildJobDefinition(jobName, newGrades)
    local filePath = GetResourcePath("qb-core").."/shared/jobs.lua"
    local backupPath = filePath .. ".backup"
    
    local originalFile = io.open(filePath, "r")
    if not originalFile then
        return false
    end
    
    local content = originalFile:read("*all")
    originalFile:close()
    
    local backup = io.open(backupPath, "w")
    if backup then
        backup:write(content)
        backup:close()
    end
    
    local lines = {}
    local file = io.open(filePath, "r")
    for line in file:lines() do
        table.insert(lines, line)
    end
    file:close()
    
    local jobStartLine = nil
    local jobEndLine = nil
    local jobLabelLine = nil
    local defaultDutyLine = nil
    
    for i, line in ipairs(lines) do
        if line:match("%['" .. jobName .. "'%]%s*=%s*{") then
            jobStartLine = i
            break
        end
    end
    
    if not jobStartLine then
        return false
    end
    
    local braceLevel = 1
    for i = jobStartLine + 1, #lines do
        local line = lines[i]
        
        if not jobLabelLine and line:match("label%s*=") then
            jobLabelLine = line
        end
        
        if not defaultDutyLine and line:match("defaultDuty%s*=") then
            defaultDutyLine = line
        end
        
        local openBraces = line:gsub("[^{]", ""):len()
        local closeBraces = line:gsub("[^}]", ""):len()
        braceLevel = braceLevel + openBraces - closeBraces
        
        if braceLevel == 0 then
            jobEndLine = i
            break
        end
    end
    
    if not jobEndLine then
        return false
    end
    
    local label = jobLabelLine and jobLabelLine:match("label%s*=%s*'([^']*)'") or "Unknown"
    local defaultDuty = defaultDutyLine and defaultDutyLine:match("defaultDuty%s*=%s*(%w+)") or "true"
    
    local gradeNumbers = {}
    local sortedGrades = {}
    
    for level, grade in pairs(newGrades) do
        local numLevel = tonumber(level)
        table.insert(gradeNumbers, numLevel)
        sortedGrades[numLevel] = grade
    end
    
    table.sort(gradeNumbers)
    
    local finalGrades = {}
    local newMapping = {}
    
    for newIndex, oldNumber in ipairs(gradeNumbers) do
        local newIndex = newIndex - 1 
        local grade = sortedGrades[oldNumber]
        
        local newGrade = {
            name = grade.name,
            payment = grade.payment
        }
        
        if grade.isboss then
            newGrade.isboss = true
        end
        
        if grade.bankAuth then
            newGrade.bankAuth = true
        end
        
        finalGrades[tostring(newIndex)] = newGrade
        newMapping[oldNumber] = newIndex
        
    end
    
    local newJobDef = {
        "['" .. jobName .. "'] = {",
        "    label = '" .. label .. "',",
        "    defaultDuty = " .. defaultDuty .. ",",
        "    grades = {"
    }
    
    for i = 0, #gradeNumbers - 1 do
        local level = tostring(i)
        local grade = finalGrades[level]
        
        local gradeLine = string.format("        ['%s'] = { name = '%s'", level, grade.name:gsub("'", "\\'"))
        
        if grade.payment then
            gradeLine = gradeLine .. string.format(", payment = %d", grade.payment)
        end
        
        if grade.isboss then
            gradeLine = gradeLine .. ", isboss = true"
        end
        
        if grade.bankAuth then
            gradeLine = gradeLine .. ", bankAuth = true"
        end
        
        gradeLine = gradeLine .. " },"
        table.insert(newJobDef, gradeLine)
    end
    
    table.insert(newJobDef, "    },")
    table.insert(newJobDef, "},")
    
    local newLines = {}
    
    for i = 1, jobStartLine - 1 do
        table.insert(newLines, lines[i])
    end
    
    for _, line in ipairs(newJobDef) do
        table.insert(newLines, line)
    end
    
    for i = jobEndLine + 1, #lines do
        table.insert(newLines, lines[i])
    end
    
    local outFile = io.open(filePath, "w")
    if not outFile then
        return false
    end
    
    for _, line in ipairs(newLines) do
        outFile:write(line .. "\n")
    end
    outFile:close()
    
    QBCore.Shared.Jobs[jobName].grades = finalGrades
    
    TriggerClientEvent('QBCore:Client:OnSharedUpdate', -1, 'Jobs', jobName, 'grades', finalGrades)
    
    TriggerEvent('QBCore:server:UpdateObject')    
    return true, newMapping
end

function SaveJobGradeChangesToFile(jobName, grades)
    local success, mapping = CompletelyRebuildJobDefinition(jobName, grades)
    
    if success and mapping then
        local hasChanges = false
        for old, new in pairs(mapping) do
            if old ~= new then
                hasChanges = true
                break
            end
        end
        
        if hasChanges then
        end
    end
    
    return success
end

function GetCurrentJobGrades(jobName)
    if not QBCore.Shared.Jobs[jobName] then
        return nil
    end
    
    return QBCore.Shared.Jobs[jobName].grades
end


RegisterNetEvent('dw-bossmenu:server:RequestRefreshJobData', function()
    TriggerEvent('QBCore:server:UpdateObject')
end)


function table.copy(t)
    local u = { }
    for k, v in pairs(t) do
        if type(v) == "table" then
            u[k] = table.copy(v)
        else
            u[k] = v
        end
    end
    return setmetatable(u, getmetatable(t))
end

-- Get employee permissions
-- Get employee permissions callback
QBCore.Functions.CreateCallback('dw-bossmenu:server:GetEmployeePermissions', function(source, cb, citizenid, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player then
        cb(false)
        return
    end
    
    -- Check for cached permissions first
    if JobPermissionsCache[jobName] and JobPermissionsCache[jobName][citizenid] then
        cb(JobPermissionsCache[jobName][citizenid])
        return
    end
    
    -- If not in cache, get from database
    MySQL.Async.fetchAll('SELECT permissions FROM job_employee_permissions WHERE citizenid = ? AND job = ?', 
        {citizenid, jobName}, function(result)
        if result and result[1] and result[1].permissions then
            local permissions = json.decode(result[1].permissions)
            
            -- Cache the results
            if not JobPermissionsCache[jobName] then
                JobPermissionsCache[jobName] = {}
            end
            JobPermissionsCache[jobName][citizenid] = permissions
            
            cb(permissions)
        else
            -- Return default permissions (all false)
            local defaultPermissions = {
                dashboard = false,
                employees = false,
                society = false,
                applications = false,
                grades = false,
                hiringfiring = false
            }
            
            cb(defaultPermissions)
        end
    end)
end)


-- Load permissions on server start
Citizen.CreateThread(function()
    Citizen.Wait(1000) -- Wait for everything to initialize
    
    -- Load all permissions into cache
    MySQL.Async.fetchAll('SELECT citizenid, job, permissions FROM job_employee_permissions', {}, function(results)
        if results and #results > 0 then
            for _, row in ipairs(results) do
                local jobName = row.job
                local citizenid = row.citizenid
                local permissions = json.decode(row.permissions)
                
                if not JobPermissionsCache[jobName] then
                    JobPermissionsCache[jobName] = {}
                end
                
                JobPermissionsCache[jobName][citizenid] = permissions
            end       
        end
    end)
end)

-- Update employee permissions
QBCore.Functions.CreateCallback('dw-bossmenu:server:UpdateEmployeePermissions', function(source, cb, citizenid, jobName, permissions)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player then
        cb({success = false, message = "Player not found"})
        return
    end
    
    if Player.PlayerData.job.name ~= jobName then
        cb({success = false, message = "You don't have permission for this action"})
        return
    end
    
    -- Check if player has boss permissions
    if not Player.PlayerData.job.isboss then
        cb({success = false, message = "You don't have permission for this action"})
        return
    end
    
    
    -- Update the permissions cache
    if not JobPermissionsCache[jobName] then
        JobPermissionsCache[jobName] = {}
    end
    JobPermissionsCache[jobName][citizenid] = permissions
    
    -- JSON encode the permissions
    local permissionsJson = json.encode(permissions)
    
    -- Save permissions to database
    MySQL.Async.execute('INSERT INTO job_employee_permissions (citizenid, job, permissions, granted_by) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE permissions = ?, granted_by = ?', 
        {citizenid, jobName, permissionsJson, Player.PlayerData.citizenid, permissionsJson, Player.PlayerData.citizenid}, 
        function(rowsChanged)
        if rowsChanged > 0 then
            cb({success = true})
            
            -- If target is online, update their permissions immediately
            local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(citizenid)
            if targetPlayer then
                TriggerClientEvent('dw-bossmenu:client:RefreshPermissions', targetPlayer.PlayerData.source, permissions)
                TriggerClientEvent('QBCore:Notify', targetPlayer.PlayerData.source, "Your job permissions have been updated", "info")
            end
            
            -- Broadcast the permission update to all players with this job for real-time sync
            local players = QBCore.Functions.GetQBPlayers()
            for _, p in pairs(players) do
                if p.PlayerData.job.name == jobName then
                    TriggerClientEvent('dw-bossmenu:client:SyncPermissions', p.PlayerData.source, citizenid, permissions)
                end
            end
            
            -- Log entry
            TriggerEvent('qb-log:server:CreateLog', 'jobmanagement', 'Employee Permissions Update', 'green', string.format('%s (%s) updated permissions for %s in job %s', 
                GetPlayerName(src), Player.PlayerData.citizenid, citizenid, jobName))
        else
            cb({success = false, message = "Failed to update permissions"})
        end
    end)
end)

QBCore.Functions.CreateCallback('dw-bossmenu:server:HireNewEmployee', function(source, cb, targetId, jobName, grade)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local Target = QBCore.Functions.GetPlayer(tonumber(targetId))
    
    if not Player then
        cb({ success = false, message = "Error: Manager not found" })
        return
    end
    
    if not Target then
        cb({ success = false, message = "Player with ID " .. targetId .. " not found" })
        return
    end
    
    if Player.PlayerData.job.name ~= jobName then
        cb({ success = false, message = "You don't have permission for this job" })
        return
    end
    
    -- Check if player has boss permissions
    if not Player.PlayerData.job.isboss then
        cb({ success = false, message = "You don't have hiring permissions" })
        return
    end
    
    -- Check if grade exists for this job
    if not QBCore.Shared.Jobs[jobName].grades[grade] then
        cb({ success = false, message = "Invalid job grade" })
        return
    end
    
    -- Set employee job
    Target.Functions.SetJob(jobName, grade)
    
    -- Notify the target
    TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, "You've been hired: " .. QBCore.Shared.Jobs[jobName].label, "success")
    
    -- Update the job data for all clients
    TriggerClientEvent('dw-bossmenu:client:JobChanged', -1, jobName)
    
    -- Log the action
    TriggerEvent('qb-log:server:CreateLog', 'jobmanagement', 'Employee Hire', 'green', string.format('%s (%s) hired %s (%s) for job %s at rank %s', 
        GetPlayerName(src), Player.PlayerData.citizenid, GetPlayerName(Target.PlayerData.source), Target.PlayerData.citizenid, jobName, grade))
    
    -- Return success
    cb({ success = true, message = "Employee hired successfully" })
end)


QBCore.Functions.CreateCallback('dw-bossmenu:server:HasJobAccess', function(source, cb, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player or Player.PlayerData.job.name ~= jobName then
        cb(false)
        return
    end
    
    -- If player is a boss, they have access
    if Player.PlayerData.job.isboss then
        cb(true)
        return
    end
    
    -- Check if player has any permissions for this job
    MySQL.Async.fetchAll('SELECT permissions FROM job_employee_permissions WHERE citizenid = @citizenid AND job = @job', {
        ['@citizenid'] = Player.PlayerData.citizenid,
        ['@job'] = jobName
    }, function(result)
        if result and result[1] and result[1].permissions then
            local permissions = json.decode(result[1].permissions)
            
            -- Check if any permission is granted
            local hasAnyPermission = false
            for _, permValue in pairs(permissions) do
                if permValue then
                    hasAnyPermission = true
                    break
                end
            end
            
            cb(hasAnyPermission)
        else
            cb(false)
        end
    end)
end)

function HasSocietyPermission(src, jobName)
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player or Player.PlayerData.job.name ~= jobName then
        return false
    end
    
    if Player.PlayerData.job.isboss then
        return true
    end
    
    local citizenid = Player.PlayerData.citizenid
    
    if JobPermissionsCache[jobName] and JobPermissionsCache[jobName][citizenid] then
        return JobPermissionsCache[jobName][citizenid].society or false
    end
    
    local result = MySQL.Sync.fetchSingle('SELECT permissions FROM job_employee_permissions WHERE citizenid = @citizenid AND job = @job', {
        ['@citizenid'] = citizenid,
        ['@job'] = jobName
    })
    
    if result and result.permissions then
        local permissions = json.decode(result.permissions)
        
        if not JobPermissionsCache[jobName] then
            JobPermissionsCache[jobName] = {}
        end
        JobPermissionsCache[jobName][citizenid] = permissions
        
        return permissions.society or false
    end
    
    return false
end

-- Create a new event to handle permission-specific actions
RegisterServerEvent('dw-bossmenu:server:PermissionAction', function(action, data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player then return end
    
    local jobName = Player.PlayerData.job.name
    local citizenid = Player.PlayerData.citizenid
    
    -- Check if player has permission for this action
    local hasPermission = false
    
    -- If player is a boss, they have all permissions
    if Player.PlayerData.job.isboss then
        hasPermission = true
    else
        -- Get permissions from database
        local result = MySQL.Sync.fetchSingle('SELECT permissions FROM job_employee_permissions WHERE citizenid = @citizenid AND job = @job', {
            ['@citizenid'] = citizenid,
            ['@job'] = jobName
        })
        
        if result and result.permissions then
            local permissions = json.decode(result.permissions)
            
            -- Check specific permission
            if action == "viewApplications" and permissions.applications then
                hasPermission = true
            elseif action == "viewEmployees" and permissions.employees then
                hasPermission = true
            elseif action == "viewSociety" and permissions.society then
                hasPermission = true
            elseif action == "viewGrades" and permissions.grades then
                hasPermission = true
            elseif action == "hiring" and permissions.hiringfiring then
                hasPermission = true
            end
        end
    end
    
    if not hasPermission then
        TriggerClientEvent('QBCore:Notify', src, "You don't have permission for this action", "error")
        return
    end
    
    -- Process the permission-specific action
    if action == "viewApplications" then
        -- Logic for viewing applications
    elseif action == "viewEmployees" then
        -- Logic for viewing employees
    elseif action == "viewSociety" then
        -- Logic for viewing society
    elseif action == "viewGrades" then
        -- Logic for viewing grades
    elseif action == "hiring" then
        -- Logic for hiring
    end
end)

-- New callback specifically for playtime updates
QBCore.Functions.CreateCallback('dw-bossmenu:server:GetPlaytimeData', function(source, cb, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    
    if not Player then
        cb(false)
        return
    end
    
    if Player.PlayerData.job.name ~= jobName then
        cb(false)
        return
    end
    
    -- Check permissions
    local hasBossAccess = Player.PlayerData.job.isboss
    local hasPermission = hasBossAccess
    
    if not hasBossAccess then
        -- Check for dashboard permission
        local result = MySQL.Sync.fetchSingle('SELECT permissions FROM job_employee_permissions WHERE citizenid = @citizenid AND job = @job', {
            ['@citizenid'] = Player.PlayerData.citizenid,
            ['@job'] = jobName
        })
        
        if result and result.permissions then
            local permissions = json.decode(result.permissions)
            hasPermission = permissions.dashboard or false
        end
    else
    end
    
    if not hasPermission then
        cb(false)
        return
    end
    
    -- Get database records for all employees of this job
    MySQL.Async.fetchAll('SELECT citizenid FROM players WHERE JSON_EXTRACT(job, "$.name") = @jobName', {
        ['@jobName'] = jobName
    }, function(employees)
        if not employees or #employees == 0 then
            cb({ employees = {} })
            return
        end
        
        local employeeData = {}
        -- Process each employee
        for _, employee in pairs(employees) do
            local citizenid = employee.citizenid
            
            -- Check if player is online
            local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(citizenid)
            local isOnline = targetPlayer ~= nil
            local playTime = 0
            
            if isOnline then
                -- Calculate playtime from PlayerJoinTimes first
                if PlayerJoinTimes[citizenid] then
                    local sessionTime = math.floor((os.time() - PlayerJoinTimes[citizenid].time) / 60)
                    
                    -- Get accumulated time from database or cache
                    local dbPlaytime = GetCachedPlaytime(citizenid, jobName)
                    
                    -- Use total time
                    playTime = dbPlaytime + sessionTime
                else 
                    -- If no record in PlayerJoinTimes, use metadata or create new tracking
                    local joinTime = targetPlayer.PlayerData.metadata.joinTime or os.time()
                    playTime = math.floor((os.time() - joinTime) / 60)
                    
                    -- Create new tracking record
                    PlayerJoinTimes[citizenid] = {
                        time = joinTime,
                        job = jobName
                    }
                end
            else
                -- For offline players, get playtime from database only
                playTime = GetCachedPlaytime(citizenid, jobName)
            end
            
            table.insert(employeeData, {
                citizenid = citizenid,
                playTime = playTime
            })
        end
            cb({ employees = employeeData })
    end)
end)

QBCore.Functions.CreateCallback('dw-bossmenu:server:GetJobGrades', function(source, cb, jobName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    
    if not Player or Player.PlayerData.job.name ~= jobName then
        cb(false)
        return
    end
    
    if not Player.PlayerData.job.isboss then
        local result = MySQL.Sync.fetchSingle('SELECT permissions FROM job_employee_permissions WHERE citizenid = @citizenid AND job = @job', {
            ['@citizenid'] = Player.PlayerData.citizenid,
            ['@job'] = jobName
        })
        
        local hasPermission = false
        if result and result.permissions then
            local permissions = json.decode(result.permissions)
            if permissions.grades then
                hasPermission = true
            end
        end
        
        if not hasPermission then
            cb(false)
            return
        end
    end
    
    if QBCore.Shared.Jobs[jobName] and QBCore.Shared.Jobs[jobName].grades then
        cb(QBCore.Shared.Jobs[jobName].grades)
    else
        cb(false)
    end
end)
