local QBCore = exports['qb-core']:GetCoreObject()
local PlayerData = {}
local isLoggedIn = false
local menuOpen = false
local allowAutoOpen = false -- Extra safeguard flag
local currentPermissions = nil
local DEBUG_MODE = true
local LAST_DEBUG = ""


-- Debug function
local function DebugPrint(msg)
    if DEBUG_MODE then
        print("^3[dw-bossmenu Debug]^7 " .. msg)
        LAST_DEBUG = msg
    end
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerData = QBCore.Functions.GetPlayerData()
    isLoggedIn = true
    menuOpen = false
    Wait(2000)
    CreateJobTargetPoints()  
    CreateApplicationPoints() 
end)

RegisterNetEvent('dw-bossmenu:client:JobChanged', function(jobName)
    if menuOpen and PlayerData.job and PlayerData.job.isboss and PlayerData.job.name == jobName then
        QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetJobData', function(jobData)
            if jobData then
                SendNUIMessage({
                    action = "refreshData",
                    jobData = jobData
                })
            end
        end, jobName)
    end
end)

function CreateApplicationPoints()    
    if not Config.EnableApplicationSystem then 
        return 
    end
    
    if not Config.ApplicationPoints then
        return
    end
    
    for jobName, location in pairs(Config.ApplicationPoints) do
        exports['qb-target']:AddBoxZone("job_application_"..jobName, location.coords, location.length, location.width, {
            name = "job_application_"..jobName,
            heading = location.heading,
            debugPoly = false, -- Set to true for testing
            minZ = location.minZ,
            maxZ = location.maxZ,
        }, {
            options = {
                {
                    type = "client",
                    event = "dw-bossmenu:client:OpenApplicationForm",
                    icon = "fas fa-file-alt",
                    label = location.label,
                    job = false, 
                    canInteract = function()
                        return true
                    end,
                    jobData = jobName
                },
            },
            distance = 2.0
        })
    end
end

-- Register event to open application form
RegisterNetEvent('dw-bossmenu:client:OpenApplicationForm', function(data)
    local jobName = data.jobData
    
    if not jobName then 
        QBCore.Functions.Notify("Invalid application spot", "error")
        return 
    end

    local jobApplication = Config.ApplicationQuestions[jobName]

    if not jobApplication then
        QBCore.Functions.Notify("Invalid application spot", "error")
        return
    end

    QBCore.Functions.TriggerCallback('dw-bossmenu:server:CheckPendingApplication', function(hasPendingApplication)
        if hasPendingApplication then
           -- QBCore.Functions.Notify("You already have a pending application for this job. Please wait for a response.", "error")
            return
        end
        
        SetNuiFocus(true, true)
        SendNUIMessage({
            action = "openApplicationForm",
            data = {
                job = {
                    name = jobName,
                    label = QBCore.Shared.Jobs[jobName].label
                },
                applicationData = jobApplication
            }
        })
    end, jobName)
end)

RegisterNetEvent('dw-bossmenu:client:SyncPermissions', function(targetCitizenid, permissions)
    if not PlayerData.job or not PlayerData.job.isboss then return end
    
    if menuOpen and selectedEmployeeForPermissions and selectedEmployeeForPermissions.citizenid == targetCitizenid then
        currentEmployeePermissions = permissions
        
        SendNUIMessage({
            action = "updatePermissionToggles",
            permissions = permissions
        })
    end
end)


RegisterNetEvent('eventName', function()
    SetNuiFocus(true, true)
    
    SendNUIMessage({
        action = "testModal",
        message = "This is a test modal"
    })
end, false)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    isLoggedIn = false
    PlayerData = {}
    menuOpen = false
end)

RegisterNUICallback('getApplications', function(data, cb)
    local jobName = data.jobName
    
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetJobApplications', function(applications)
        cb(applications)
    end, jobName)
end)


RegisterNUICallback('updateApplicationStatus', function(data, cb)
    TriggerServerEvent('dw-bossmenu:server:UpdateApplicationStatus', data.applicationId, data.status, data.notes)
    cb('ok')
end)
RegisterNetEvent('QBCore:Client:OnJobUpdate', function(JobInfo)
    local oldJob = PlayerData.job and PlayerData.job.name or "none"
    PlayerData.job = JobInfo
    
    -- If the menu is open, refresh it
    if menuOpen then
        if PlayerData.job.isboss then
            QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetJobData', function(jobData)
                if jobData then
                    SendNUIMessage({
                        action = "refreshData",
                        jobData = jobData
                    })
                end
            end, PlayerData.job.name)
        else
            -- If the player is no longer a boss, close the menu
            SetNuiFocus(false, false)
            SendNUIMessage({ action = "closeUI" })
            menuOpen = false
        end
    end
end)

-- Create ONLY interaction points for job management
function CreateJobTargetPoints()
    -- First, remove any existing zones to prevent duplicate opening
    for jobName, _ in pairs(Config.Locations) do
        exports['qb-target']:RemoveZone("jobmanagement_"..jobName)
        
        -- Also remove any possible extra zones for this job
        local i = 1
        while true do
            local zoneExists = exports['qb-target']:RemoveZone("jobmanagement_"..jobName.."_"..i)
            if not zoneExists then
                break
            end
            i = i + 1
        end
    end
    
    -- Create fresh targets
    for jobName, jobData in pairs(Config.Locations) do
        local jobLabel = jobData.label
        
        -- Process each location for this job
        for locationIndex, location in ipairs(jobData.locations) do
            local zoneName = "jobmanagement_"..jobName
            
            -- For additional locations, add an index to the zone name
            if locationIndex > 1 then
                zoneName = zoneName.."_"..locationIndex
            end
            
            exports['qb-target']:AddBoxZone(zoneName, location.coords, location.length, location.width, {
                name = zoneName,
                heading = location.heading,
                debugPoly = false,
                minZ = location.minZ,
                maxZ = location.maxZ,
            }, {
                options = {
                    {
                        type = "client",
                        event = "dw-bossmenu:client:TriggerOpenManager", 
                        icon = "fas fa-briefcase",
                        label = "Manage " .. jobLabel,
                        job = jobName,
                        canInteract = function()
                            -- Allow if player is boss or has any permissions for this job
                            if PlayerData.job and PlayerData.job.name == jobName then
                                if PlayerData.job.isboss then
                                    return true
                                else
                                    -- We can't check permissions here directly as it requires a callback
                                    -- So we'll check in the TriggerOpenManager event
                                    return true
                                end
                            end
                            return false
                        end,
                        jobData = jobName
                    },
                },
                distance = 2.0
            })
        end
    end
end

RegisterNetEvent('dw-bossmenu:client:TriggerOpenManager', function(data)
    TriggerServerEvent('dw-bossmenu:server:RequestRefreshJobData')
    
    if not data or not data.jobData then
        return
    end
    
    -- Prevent double-opening
    if menuOpen then
        return
    end
    
    local jobName = data.jobData
    
    -- Multiple validation checks
    if not isLoggedIn then
        return
    end
    
    if not PlayerData.job then
        return
    end
    
    if PlayerData.job.name ~= jobName then
        QBCore.Functions.Notify("You are not part of this job", "error")
        return
    end
    
    -- Check if boss or has permissions
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:HasJobAccess', function(hasAccess) 
        if not hasAccess then
            QBCore.Functions.Notify("You don't have permission to manage this job", "error")
            return
        end
        
        -- Proceed with opening the manager
        OpenJobManager(jobName)
    end, jobName)
end)

-- Register the NUI callback for updateEmployeePermissions
RegisterNUICallback('updateEmployeePermissions', function(data, cb)
    if not data.citizenid or not data.jobName or not data.permissions then
        cb({success = false, message = "Invalid data"})
        return
    end    
    -- Trigger server event to update permissions
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:UpdateEmployeePermissions', function(result)
        cb(result) 
    end, data.citizenid, data.jobName, data.permissions)
end)

RegisterNUICallback('getEmployeePermissions', function(data, cb)
    local citizenid = data.citizenid
    local jobName = data.jobName
    
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetEmployeePermissions', function(permissions)
        cb(permissions)
    end, citizenid, jobName)
end)

RegisterNetEvent('dw-bossmenu:client:RefreshPermissions', function(permissions)
    if not PlayerData.job then return end
    
    if permissions then
        -- If permissions were provided directly, update them
        currentPermissions = permissions
        
        -- If menu is open, refresh it with new permissions
        if menuOpen then
            SendNUIMessage({
                action = "updatePermissions",
                permissions = permissions
            })
        end
    else
        -- Otherwise, request current permissions
        QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetEmployeePermissions', function(newPermissions)
            if newPermissions then
                currentPermissions = newPermissions
                
                -- If menu is open, refresh it with new permissions
                if menuOpen then
                    SendNUIMessage({
                        action = "updatePermissions", 
                        permissions = newPermissions
                    })
                end
            end
        end, PlayerData.citizenid, PlayerData.job.name)
    end
end)
-- Separated function to handle the actual opening
function OpenJobManager(jobName)
    if menuOpen then return end
    
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetJobData', function(jobData)
        if not jobData then
            QBCore.Functions.Notify("Unable to load job data", "error")
            return
        end        
        -- Store received permissions
        currentPermissions = jobData.permissions
        
        QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetSettings', function(settings)
            if not settings then
                return
            end
            QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetSocietyData', function(societyData)
                if not societyData then
                end                
                menuOpen = true
                
                SetNuiFocus(true, true)
                SendNUIMessage({
                    action = "openUI",
                    jobData = jobData,
                    jobName = jobName,
                    playerJob = PlayerData.job,
                    settings = settings,
                    societyData = societyData,
                    permissions = currentPermissions
                })
            end, jobName)
        end)
    end, jobName)
end


RegisterNUICallback('checkPermission', function(data, cb)
    local permissionType = data.permissionType
    
    if PlayerData.job and PlayerData.job.isboss then
        cb(true)
        return
    end
    
    -- If we have stored permissions, check them
    if currentPermissions and currentPermissions[permissionType] then
        cb(true)
        return
    end
    
    -- Default deny if no permissions found
    cb(false)
end)

-- Function to check permissions before certain actions
function HasPermission(permissionType)
    -- If player is a boss, they have all permissions
    if PlayerData.job and PlayerData.job.isboss then
        return true
    end
    
    -- If we have stored permissions, check them
    if currentPermissions and currentPermissions[permissionType] then
        return true
    end
    
    -- Default deny if no permissions found
    return false
end

-- Block the original event to prevent any other scripts from triggering it
RegisterNetEvent('dw-bossmenu:client:OpenManager', function()
    DebugPrint("Blocked automatic opening from original event")
end)

-- Refresh data event handler
RegisterNetEvent('dw-bossmenu:client:RefreshData', function()
    if isLoggedIn and PlayerData.job and PlayerData.job.isboss and menuOpen then
        QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetJobData', function(jobData)
            if jobData then
                SendNUIMessage({
                    action = "refreshData",
                    jobData = jobData
                })
            end
        end, PlayerData.job.name)
    end
end)

-- NUI Callbacks
RegisterNUICallback('closeUI', function(_, cb)
    SetNuiFocus(false, false)
    menuOpen = false
    cb('ok')
end)

RegisterNUICallback('showFireConfirmMenu', function(data, cb)
    local citizenid = data.citizenid
    local employeeName = data.name
    
    ShowFireConfirmationMenu(citizenid, employeeName)
    
    cb('ok')
end)

function ShowFireConfirmationMenu(citizenid, employeeName)
    local headerText = "Fire Employee"
    local message = "Are you sure you want to fire " .. employeeName .. "?"
    
    local menuOptions = {
        {
            header = "Confirm Firing",
            txt = "Yes, fire this employee",
            params = {
                event = "dw-bossmenu:client:FireEmployeeConfirmed",
                args = {
                    citizenid = citizenid,
                    confirmed = true
                }
            }
        },
        {
            header = "Cancel",
            txt = "No, keep this employee",
            params = {
                event = "dw-bossmenu:client:FireEmployeeConfirmed",
                args = {
                    citizenid = citizenid,
                    confirmed = false
                }
            }
        }
    }
    
    exports['qb-menu']:openMenu(menuOptions)
end

function ShowCustomFireMenu(citizenid, employeeName)
    SetNuiFocus(true, true)
    
    SendNUIMessage({
        action = "showCustomFireMenu",
        name = employeeName,
        citizenid = citizenid
    })
end

RegisterNUICallback("submitApplication", function(data, cb) 
    SetNuiFocus(false, false)
    TriggerServerEvent("dw-bossmenu:server:SubmitApplication", data.jobName, data.answers)
end)

RegisterNUICallback('fireMenuResponse', function(data, cb)
    SetNuiFocus(false, false)
    
    SendNUIMessage({
        action = "fireEmployeeResponse",
        confirmed = data.confirmed,
        citizenid = data.citizenid
    })
    
    cb('ok')
end)

RegisterNetEvent('dw-bossmenu:client:FireEmployeeConfirmed', function(data)
    SendNUIMessage({
        action = "fireEmployeeResponse",
        confirmed = data.confirmed,
        citizenid = data.citizenid
    })
end)

RegisterNUICallback('updateEmployee', function(data, cb)
    TriggerServerEvent('dw-bossmenu:server:UpdateEmployee', data.citizenid, PlayerData.job.name, data.grade)
    cb('ok')
end)

RegisterNUICallback('removeEmployee', function(data, cb)
    TriggerServerEvent('dw-bossmenu:server:RemoveEmployee', data.citizenid, PlayerData.job.name)
    cb('ok')
end)

RegisterNUICallback('saveSettings', function(data, cb)
    TriggerServerEvent('dw-bossmenu:server:SaveSettings', data)
    cb('ok')
end)

-- Refresh data
RegisterNUICallback('refreshData', function(_, cb)
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetJobData', function(jobData)
        if jobData then
            cb(jobData)
        else
            cb(false)
        end
    end, PlayerData.job.name)
end)

-- Extra safeguard for resource start/stop
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end    
    -- Wait to ensure the server is fully loaded
    Wait(3000)
    -- Set up player data if player is already loaded
    if LocalPlayer.state.isLoggedIn then
        PlayerData = QBCore.Functions.GetPlayerData()
        isLoggedIn = true
        CreateJobTargetPoints()
        CreateApplicationPoints()
    end
end)

-- Command to manually trigger the job manager (for testing/emergency)
RegisterCommand('fixjobmanager', function()
    CreateJobTargetPoints()
    QBCore.Functions.Notify("Job Manager target points refreshed", "success")
end, false)

CreateThread(function()
    while true do
        Wait(60000) -- Update every minute
        
        -- Only refresh if menu is open
        if menuOpen then
            TriggerServerEvent('dw-bossmenu:server:RefreshPlayTime')
        end
        
        Wait(60000) -- Wait another minute before next check
    end
end)

RegisterNUICallback('getSocietyData', function(data, cb)
    if not data.jobName then
        cb(false)
        return
    end
    
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetSocietyData', function(societyData)
        if societyData then
            cb(societyData)
        else
            cb(false)
        end
    end, data.jobName)
end)

RegisterNUICallback('depositMoney', function(data, cb)
    if not data.amount or not data.jobName then
        cb({success = false, message = "Missing required data"})
        return
    end
    
    TriggerServerEvent('dw-bossmenu:server:DepositMoney', data.amount, data.note, data.jobName)
    cb({success = true})
end)

RegisterNUICallback('withdrawMoney', function(data, cb)
    if not data.amount or not data.jobName then
        cb({success = false, message = "Missing required data"})
        return
    end
    
    TriggerServerEvent('dw-bossmenu:server:WithdrawMoney', data.amount, data.note, data.jobName)
    cb({success = true})
end)

RegisterNUICallback('transferMoney', function(data, cb)
    if not data.citizenid or not data.amount or not data.jobName then
        cb({success = false, message = "Missing required data"})
        return
    end
    
    TriggerServerEvent('dw-bossmenu:server:TransferMoney', data.citizenid, data.amount, data.note, data.jobName)
    cb({success = true})
end)

RegisterNUICallback('showNotification', function(data, cb)
    local message = data.message or "Error"
    local type = data.type or "error"
    QBCore.Functions.Notify(message, type)
    
    cb('ok')
end)

RegisterNetEvent('dw-bossmenu:client:OpenApplicationForm', function(data)
    local jobName = data.jobData
    
    if not jobName then 
        QBCore.Functions.Notify("Invalid application spot", "error")
        return 
    end

    local jobApplication = Config.ApplicationQuestions[jobName]

    if not jobApplication then
        QBCore.Functions.Notify("Invalid application spot", "error")
        return
    end
    
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:CheckApplicationStatus', function(result)
        if not result.canApply then
            QBCore.Functions.Notify(result.message, "error")
            return
        end
        
        SetNuiFocus(true, true)
        SendNUIMessage({
            action = "openApplicationForm",
            data = {
                job = {
                    name = jobName,
                    label = QBCore.Shared.Jobs[jobName].label
                },
                applicationData = jobApplication
            }
        })
    end, jobName)
end)


-- Register client callback for this new function
RegisterNUICallback('getPlaytimeData', function(data, cb)
    if not data or not data.jobName then
        cb({success = false, message = "Missing job name"})
        return
    end    
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetPlaytimeData', function(playtimeData)
        if playtimeData then
            cb(playtimeData)
        else
            cb({success = false, message = "Failed to get playtime data", employees = {}})
        end
    end, data.jobName)
end)


RegisterNUICallback('hireEmployee', function(data, cb)
    if not data.targetId or not data.jobName or not data.grade then
        cb({ success = false, message = "Missing required data" })
        return
    end
    
    -- Convert to numbers if needed
    local targetId = tonumber(data.targetId)
    local grade = data.grade
    
    -- Trigger server event
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:HireNewEmployee', function(result)
        cb(result)
    end, targetId, data.jobName, grade)
end)

RegisterNUICallback('checkPermission', function(data, cb)
    local permissionType = data.permissionType
    
    -- If player is a boss, they have all permissions
    if PlayerData.job and PlayerData.job.isboss then
        cb(true)
        return
    end
    
    -- If we have stored permissions, check them
    if currentPermissions and currentPermissions[permissionType] then
        cb(true)
        return
    end
    
    -- Default deny if no permissions found
    cb(false)
end)


RegisterNUICallback('updateJobGrade', function(data, cb)
    if not data.jobName or not data.gradeLevel or not data.gradeName or not data.gradePayment then
        cb({success = false, message = "Missing required data"})
        return
    end
    
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:UpdateJobGrade', function(result)
        cb(result)
    end, data.jobName, data.gradeLevel, data.gradeName, data.gradePayment, data.gradeIsBoss)
end)

RegisterNUICallback('addJobGrade', function(data, cb)
    if not data.jobName or not data.gradeName or not data.gradePayment then
        cb({success = false, message = "Missing required data"})
        return
    end
    
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:AddJobGrade', function(result)
        cb(result)
    end, data.jobName, data.gradeName, data.gradePayment, data.gradeIsBoss)
end)

RegisterNUICallback('deleteJobGrade', function(data, cb)
    if not data.jobName or not data.gradeLevel then
        cb({success = false, message = "Missing required data"})
        return
    end
    
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:DeleteJobGrade', function(result)
        cb(result)
    end, data.jobName, data.gradeLevel)
end)

RegisterNUICallback('getJobGrades', function(data, cb)
    if not data or not data.jobName then
        cb(false)
        return
    end
        
    QBCore.Functions.TriggerCallback('dw-bossmenu:server:GetJobGrades', function(gradesData)
        if gradesData then
            cb(gradesData)
        else
            cb(false)
        end
    end, data.jobName)
end)
