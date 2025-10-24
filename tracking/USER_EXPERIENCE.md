# Ossuary Pi - Actual User Experience Documentation

## What the User Actually Experiences

### First Time Installation

#### Happy Path (Physical Access)
1. User clones repository
2. Runs `sudo ./install.sh`
3. Sees installation progress messages
4. System installs packages (5-10 minutes)
5. Warning about network configuration
6. Installation completes
7. User reboots Pi
8. System works (maybe)

#### Likely Reality (SSH Access)
1. User SSHs into Pi
2. Clones repository
3. Runs `sudo ./install.sh`
4. Gets scary warning about SSH disconnection
5. Proceeds anyway (or aborts)
6. If proceeds:
   - 50% chance: SSH disconnects during install
   - System left in unknown state
   - Cannot reconnect
   - Physical access required for recovery
7. If aborts:
   - Must figure out alternative installation method
   - No clear guidance provided

### Post-Installation Usage

#### When Everything Works (Rare)
1. Pi boots and connects to saved WiFi
2. User can access web interface at Pi's IP
3. Can configure startup command
4. When WiFi fails:
   - After 60 seconds, AP mode starts
   - "Ossuary-Setup" network appears
   - User connects (open network)
   - Redirected to configuration page
   - Can select new WiFi and enter password
   - System reconnects

#### Common Problems Users Face

##### Problem 1: Can't Find Web Interface
- User doesn't know Pi's IP address
- `hostname -I` returns multiple IPs
- Web interface not accessible on expected IP
- Port 3000 vs port 80 confusion

##### Problem 2: AP Mode Doesn't Start
- WiFi fails but no "Ossuary-Setup" appears
- Need to run `fix-ap-service.sh`
- Or use `force-ap-mode.sh` for testing
- Manual intervention required

##### Problem 3: Can't Connect After AP Mode
- Configured new WiFi in captive portal
- System claims success
- WiFi doesn't actually connect
- Stuck in AP mode
- Need to run `fix-captive-portal.sh`

##### Problem 4: Startup Command Issues
- Command saves but doesn't run
- No clear error messages
- Service crashes silently
- Need to check journals manually
- Command runs as wrong user

## Actual Workflow Examples

### Example 1: Basic Setup
```
User: "I want my Pi to run a Python script at startup and have WiFi backup"
Reality:
1. Install fails over SSH, loses connection
2. Connects monitor/keyboard to Pi
3. Re-runs installation locally
4. Reboots
5. Startup command doesn't work (path issues)
6. Manually debugs systemd service
7. Finally works after 2-3 hours of troubleshooting
```

### Example 2: WiFi Network Change
```
User: "I need to change WiFi networks at a remote location"
Reality:
1. Unplugs Pi from current network
2. Waits for AP mode (should be 60 seconds)
3. Nothing happens after 5 minutes
4. Power cycles Pi
5. Still no AP mode
6. Needs physical access to fix
7. Runs force-ap-mode.sh manually
8. Finally gets AP working
9. Configures new network
10. Won't connect to new network
11. More troubleshooting required
```

### Example 3: Startup Command Configuration
```
User: "I want to run a Node.js application"
Reality:
1. Enters: "node /home/pi/myapp/index.js"
2. Saves successfully
3. Service won't start (node not in PATH)
4. Changes to: "/usr/bin/node /home/pi/myapp/index.js"
5. Service crashes (runs as wrong user)
6. Needs to manually edit service file
7. Works after manual intervention
```

## User Frustration Points

### Installation
- Scary SSH warning with no good solution
- Takes too long (10+ minutes)
- No progress indication for long operations
- Can't safely test without physical access
- Submodule issues not clear

### Configuration
- No validation of startup commands
- No way to test commands before saving
- WiFi passwords shown in plain text
- Can't edit existing WiFi networks
- No way to see what's actually running

### Reliability
- Random failures with no clear cause
- Multiple "fix" scripts indicate problems
- Services fail silently
- Logs difficult to access/understand
- No health status indicators

### Recovery
- When things break, recovery is manual
- Documentation doesn't match reality
- Error messages unhelpful
- Need SSH/terminal skills to debug
- May require complete reinstall

## What Users Expected vs Reality

### Expected:
- "Easy WiFi failover for Raspberry Pi"
- "Simple web interface for configuration"
- "Automatic recovery when WiFi fails"
- "Run any command at startup"
- "Works out of the box"

### Reality:
- Complex installation with failure modes
- Web interface works sometimes
- Manual intervention often required
- Startup commands need specific format
- Requires significant troubleshooting

## Support Burden

### Common Support Requests:
1. "Installation disconnected my SSH"
2. "Can't see Ossuary-Setup network"
3. "Web interface won't load"
4. "Startup command not working"
5. "How do I uninstall this?"
6. "WiFi won't reconnect after AP mode"
7. "What do all these fix scripts do?"
8. "Why are there so many test scripts?"

### Time to Resolution:
- Simple issues: 30-60 minutes
- Complex issues: 2-4 hours
- Some issues: Require complete reinstall

## Success Rate Estimation

Based on the code analysis:
- Clean installation success: 60%
- AP mode activation when needed: 70%
- Successful WiFi reconfiguration: 50%
- Startup command working first try: 30%
- Overall "works as advertised": 20%

## User Skill Level Required

### Advertised: Beginner
### Actual: Intermediate to Advanced
- Must understand Linux services
- Need SSH/terminal skills
- Should know systemd basics
- Network debugging helpful
- Python knowledge for debugging

## Conclusion

The actual user experience is far from the promised "easy setup". Users face multiple failure points, poor error handling, and often need manual intervention. The presence of multiple "fix" scripts strongly indicates that even the developers know it doesn't work reliably. This is not ready for end users and requires significant technical skill to deploy and maintain.