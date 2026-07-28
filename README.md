# Sigma-Spy
- **A complete Remote Spy with an incredible parser that captures Client receives and pushes with Actor support!**

# Notices
- **Sigma Spy will have bugs, please report any bugs by opening an issue on Github**
- **If you gave a suggestion, please post it in the discussions**
- **Please do not use Potassium in games with Actors as Potassium's crude implimentations break**
# Loadstring
```
--// SigmaSpy-Remake @EnemySaga
loadstring(game:HttpGet("https://raw.githubusercontent.com/EnemySaga/SigmaSpy-Remake/refs/heads/main/Main.lua"), "Sigma Spy")()
```
# Features ⚡
- **Actors support**
- **__index and __namecall support**
- **Decompile large scripts**
- **Block remotes from firing**
- **Spoof return values (Return spoofs.lua)**
- **Keybinds for toggling options**
- **Argument values for log titles**
- **Wide range of supported data types**
- **Logging client recieves (e.g OnClientEvent)**
- **Variable compression in the parser**
- **Remote stacking (optional)**
# Required functions ⚠️
- **Sigma spy will prompt you if your executor does not support it. Your executor must support these functions in order  for it to function:** 
  - **create_comm_channel**
  - **get_comm_channel**
  - **hookmetamethod**
  - **getrawmetatable**
  - **setreadonly**
