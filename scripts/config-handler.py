#!/usr/bin/env python3
"""
Simple configuration handler for Ossuary
Reads config from WiFi Connect's custom UI and saves it
"""

import json
import os
import sys
from pathlib import Path

CONFIG_FILE = '/etc/ossuary/config.json'
WIFI_CONNECT_CONFIG = '/tmp/ossuary_config.json'

def load_config():
    """Load existing configuration"""
    if Path(CONFIG_FILE).exists():
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    return {}

def save_config(config):
    """Save configuration"""
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    with open(CONFIG_FILE, 'w') as f:
        json.dump(config, f, indent=2)
    print(f"Configuration saved to {CONFIG_FILE}")

def check_wifi_connect_config():
    """Check if WiFi Connect passed any configuration"""
    if Path(WIFI_CONNECT_CONFIG).exists():
        try:
            with open(WIFI_CONNECT_CONFIG, 'r') as f:
                wifi_config = json.load(f)

            # Remove temp file
            os.remove(WIFI_CONNECT_CONFIG)
            return wifi_config
        except Exception as e:
            print(f"Error reading WiFi Connect config: {e}")
    return None

def main():
    # Load existing config
    config = load_config()

    # Check for WiFi Connect config
    wifi_config = check_wifi_connect_config()

    if wifi_config and 'startup_command' in wifi_config:
        config['startup_command'] = wifi_config['startup_command']
        print(f"Updated startup command: {wifi_config['startup_command']}")

    # Save configuration
    if config:
        save_config(config)

    return 0

if __name__ == '__main__':
    sys.exit(main())