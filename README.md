# 🏢 DW Boss Menu - Advanced Job Management System

  
![Version](https://img.shields.io/badge/Version-1.1.0-blue)
![QB-Core](https://img.shields.io/badge/Framework-QB--Core-red)
![License](https://img.shields.io/badge/License-Free-brightgreen)

## 📋 Overview

![image](https://github.com/user-attachments/assets/6720ed2e-790c-408b-af4e-46072203378b)


**DW Boss Menu** reimagines the traditional boss menu with a modern UI and extensive management capabilities. This resource provides job owners and managers with a sleek, feature-packed interface to efficiently run their organization.
## ✨ Key Features

### 👥 Employee Management
- **Hire/Fire System**: Easily add new employees or remove existing ones
- **Promotion Controls**: Manage employee ranks with just a few clicks
- **Real-time Monitoring**: Track online status and playtime statistics
- **Location Tracking**: See where your employees are working
- **Detailed Statistics**: View performance metrics and activity data

### 💰 Society Finance System
- **Complete Financial Control**: Manage your organization's funds securely
- **Transaction History**: Detailed logs of all financial activities
- **Analytical Tools**: Visual charts showing financial patterns
- **Transfer System**: Send funds directly to employees
- **Deposit/Withdraw**: Easy money management with notes system

### 📝 Job Application System
- **Custom Application Forms**: Fully configurable questions for each job
- **Strategic Placement**: Set up application points anywhere on the map
- **Review Interface**: Accept, reject, or mark applications as complete
- **Anti-Spam Measures**: Cooldown periods for rejected applications
- **Notification System**: Get alerts when new applications arrive

### 🔐 Permission Framework
- **Granular Access Control**: Create custom permission profiles
- **Management Hierarchy**: Perfect for lieutenants, managers, and deputies
- **Security Controls**: Protect sensitive operations
- **Activity Logs**: Keep track of management actions

### 🎨 User-Friendly Interface
- **Modern Design**: Sleek, responsive UI with smooth animations
- **Appearance Options**: Dark/light mode toggle and multiple theme colors
- **Customizable Settings**: UI preferences saved per player
- **Real-time Updates**: Live data refreshing

---

## 🔧 Technical Features

- **Efficient Resource Usage**: Smart caching system to minimize server load
- **Detailed Tracking**: Employee playtime and activity monitoring
- **Persistent Settings**: User preferences saved to database
- **Secure Validation**: All operations validated server-side
- **Comprehensive Configuration**: Easily customize all aspects

---

![image](https://github.com/user-attachments/assets/4a4d28b0-83c5-41bf-b9e9-5535a981dda3)
![image](https://github.com/user-attachments/assets/7215bdbf-0c68-4ebb-aecb-1f9558c257a7)
![image](https://github.com/user-attachments/assets/c934baab-dcec-4f76-8207-3c725a1a9382)
![image](https://github.com/user-attachments/assets/6dc08a76-d70a-4a60-b341-eb63246c0270)
![image](https://github.com/user-attachments/assets/05bc554d-9f51-47d6-a4e7-3da2db48b1fb)






## 📦 Installation

1. **Download** the resource and extract to your resources folder
2. **Import** the included SQL file to your database
3. **Add the following at the end of your qb-banking server.lua** 
RegisterNetEvent('qb-banking:server:RefreshAccounts', function()
    -- Reload all accounts from database
    MySQL.Async.fetchAll('SELECT * FROM bank_accounts WHERE account_type = ?', {'job'}, function(accounts)
        if accounts and #accounts > 0 then
            for _, account in ipairs(accounts) do
                -- השתמש ברענון דרך אירוע קיים במקום לנסות לעדכן ישירות
                -- במקום QBCore.Functions.ExecuteSql שלא קיים
                TriggerEvent('qb-banking:server:UpdateAccount', account.account_name, 0, "refresh")
                
                print('Refreshed account: ' .. account.account_name .. ' with balance: ' .. account.account_balance)
            end
        end
    end)
end)

RegisterNetEvent('qb-banking:server:ForceRefresh', function()
    print("Banking accounts refresh triggered")
end)
4. **Add** `ensure dw-bossmenu` to your server.cfg
5. **Configure** locations and application questions in the config.lua

```lua
-- Example config for job locations
Config.Locations = {
    ["police"] = {
        coords = vector3(447.87, -973.55, 30.69),
        width = 1.0,
        length = 1.0,
        heading = 0,
        minZ = 30.0,
        maxZ = 31.0,
        jobLabel = "Police Department"
    },
    -- Add more jobs as needed
}
```

---

## 🔗 Dependencies

- **QB-Core**: Framework
- **oxmysql**: Database handler



## 📝 License

This resource is **FREE** for the community. You may use and modify it as you wish, but please respect the following:

- Do not redistribute as paid content
- Maintain credits to original author
- Share improvements with the community

---

## 📞 Support

If you encounter any issues or have suggestions:

- Open an issue on GitHub
- Contact me on Discord: [https://discord.gg/7Ds8V64fk8]
- Leave a comment on the CFX forum post

---

  
### Enjoy DW Boss Menu and happy roleplaying!

