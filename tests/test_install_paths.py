import os
import re

def test_install_launchagents_plist_paths():
    script_path = "scripts/install-launchagents.sh"
    with open(script_path, "r") as f:
        content = f.read()
    
    # Search for install_plist calls, ignoring commented-out lines
    matches = re.findall(r'^\s*install_plist\s+"([^"]+)"', content, re.MULTILINE)
    
    for plist_path in matches:
        # Resolve variables like $REPO_DIR, $LAUNCHD_TEMPLATES_DIR
        resolved_path = plist_path.replace("$REPO_DIR/", "").replace("$LAUNCHD_TEMPLATES_DIR/", "launchd/").replace("$CONFIG_DIR/", "launchd/").replace("$MONITOR_AGENT_PLIST", "launchd/ai.smartclaw.monitor-agent.plist.template").replace("$ANTIG_CMUX_PLIST", "launchd/ai.smartclaw.antig-cmux-loop.plist.template").replace("$AO7GREEN_JLEECHANCLAW_PLIST", "launchd/ai.smartclaw.schedule.ao7green-smartclaw.plist.template").replace("$MEMORY_SYNC_PLIST", "launchd/ai.smartclaw.claude-memory-sync.plist.template")
        
        # Some paths might still have variables we can't resolve easily, ignore them
        if "$" in resolved_path:
            continue
            
        assert os.path.exists(resolved_path), f"Plist path {resolved_path} in {script_path} does not exist"

if __name__ == "__main__":
    test_install_launchagents_plist_paths()
