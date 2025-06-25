// VectorMCP Chrome Extension - Background Script
// Handles communication with VectorMCP server

class VectorMCPClient {
  constructor() {
    this.serverUrl = 'http://localhost:8000';
    this.connected = false;
    this.pollInterval = null;
    this.currentTab = null;
  }

  async start() {
    console.log('VectorMCP: Starting browser automation client...');
    
    // Get current active tab
    const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
    this.currentTab = tabs[0];
    
    // Start polling for commands
    this.startPolling();
    
    // Send initial ping
    this.sendPing();
  }

  async sendPing() {
    try {
      const response = await fetch(`${this.serverUrl}/browser/ping`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ timestamp: Date.now() })
      });
      
      if (response.ok) {
        this.connected = true;
        console.log('VectorMCP: Connected to server');
      }
    } catch (error) {
      this.connected = false;
      console.log('VectorMCP: Server not available');
    }
  }

  startPolling() {
    // Poll for commands every 1 second
    this.pollInterval = setInterval(() => {
      this.pollForCommands();
    }, 1000);
  }

  async pollForCommands() {
    if (!this.connected) {
      this.sendPing();
      return;
    }

    try {
      const response = await fetch(`${this.serverUrl}/browser/poll`);
      const data = await response.json();
      
      if (data.commands && data.commands.length > 0) {
        console.log(`VectorMCP: Received ${data.commands.length} commands`);
        
        for (const command of data.commands) {
          await this.executeCommand(command);
        }
      }
    } catch (error) {
      console.error('VectorMCP: Polling error:', error);
      this.connected = false;
    }
  }

  async executeCommand(command) {
    console.log(`VectorMCP: Executing command: ${command.action}`);
    
    try {
      let result;
      
      switch (command.action) {
        case 'navigate':
          result = await this.navigate(command.params);
          break;
        case 'click':
          result = await this.click(command.params);
          break;
        case 'type':
          result = await this.type(command.params);
          break;
        case 'snapshot':
          result = await this.snapshot(command.params);
          break;
        case 'screenshot':
          result = await this.screenshot(command.params);
          break;
        case 'getConsoleLogs':
          result = await this.getConsoleLogs(command.params);
          break;
        default:
          throw new Error(`Unknown command: ${command.action}`);
      }
      
      // Send successful result back to server
      await this.sendResult(command.id, true, result);
      
    } catch (error) {
      console.error(`VectorMCP: Command failed:`, error);
      await this.sendResult(command.id, false, null, error.message);
    }
  }

  async navigate(params) {
    const { url, include_snapshot } = params;
    
    // Get current active tab if not set
    if (!this.currentTab) {
      const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
      this.currentTab = tabs[0];
    }
    
    // Update current tab or create new one
    await chrome.tabs.update(this.currentTab.id, { url });
    
    // Wait for navigation to complete
    await new Promise((resolve) => {
      const listener = (tabId, changeInfo) => {
        if (tabId === this.currentTab.id && changeInfo.status === 'complete') {
          chrome.tabs.onUpdated.removeListener(listener);
          resolve();
        }
      };
      chrome.tabs.onUpdated.addListener(listener);
      
      // Timeout after 10 seconds
      setTimeout(() => {
        chrome.tabs.onUpdated.removeListener(listener);
        resolve();
      }, 10000);
    });
    
    const result = { url };
    
    if (include_snapshot) {
      result.snapshot = await this.snapshot({});
    }
    
    return result;
  }

  async click(params) {
    const { selector, coordinate } = params;
    
    // Inject script to perform click
    const results = await chrome.scripting.executeScript({
      target: { tabId: this.currentTab.id },
      func: (selector, coordinate) => {
        if (selector) {
          const element = document.querySelector(selector);
          if (element) {
            element.click();
            return { success: true, method: 'selector' };
          } else {
            throw new Error(`Element not found: ${selector}`);
          }
        } else if (coordinate) {
          const [x, y] = coordinate;
          const element = document.elementFromPoint(x, y);
          if (element) {
            element.click();
            return { success: true, method: 'coordinate' };
          } else {
            throw new Error(`No element at coordinates: ${x}, ${y}`);
          }
        } else {
          throw new Error('Either selector or coordinate must be provided');
        }
      },
      args: [selector, coordinate]
    });
    
    return results[0].result;
  }

  async type(params) {
    const { text, selector, coordinate } = params;
    
    const results = await chrome.scripting.executeScript({
      target: { tabId: this.currentTab.id },
      func: (text, selector, coordinate) => {
        let element;
        
        if (selector) {
          element = document.querySelector(selector);
        } else if (coordinate) {
          const [x, y] = coordinate;
          element = document.elementFromPoint(x, y);
        }
        
        if (!element) {
          throw new Error('Target element not found');
        }
        
        // Focus and clear the element
        element.focus();
        element.value = '';
        
        // Type the text
        element.value = text;
        
        // Trigger input events
        element.dispatchEvent(new Event('input', { bubbles: true }));
        element.dispatchEvent(new Event('change', { bubbles: true }));
        
        return { success: true, text };
      },
      args: [text, selector, coordinate]
    });
    
    return results[0].result;
  }

  async snapshot(params) {
    // Get current active tab if not set
    if (!this.currentTab) {
      const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
      this.currentTab = tabs[0];
    }
    
    // Get ARIA accessibility tree
    const results = await chrome.scripting.executeScript({
      target: { tabId: this.currentTab.id },
      func: () => {
        // Simple ARIA snapshot - in real implementation this would be more comprehensive
        const elements = [];
        
        // Get interactive elements
        const interactiveSelectors = [
          'input', 'button', 'a[href]', 'select', 'textarea',
          '[role="button"]', '[role="link"]', '[role="textbox"]'
        ];
        
        interactiveSelectors.forEach(selector => {
          document.querySelectorAll(selector).forEach(el => {
            const rect = el.getBoundingClientRect();
            if (rect.width > 0 && rect.height > 0) {
              elements.push({
                role: el.getAttribute('role') || el.tagName.toLowerCase(),
                name: el.textContent?.trim() || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '',
                value: el.value || '',
                href: el.href || '',
                x: Math.round(rect.x),
                y: Math.round(rect.y),
                width: Math.round(rect.width),
                height: Math.round(rect.height)
              });
            }
          });
        });
        
        // Convert to YAML-like format
        let yaml = '# ARIA Accessibility Snapshot\n';
        elements.forEach((el, i) => {
          yaml += `- role: ${el.role}\n`;
          yaml += `  name: "${el.name}"\n`;
          if (el.value) yaml += `  value: "${el.value}"\n`;
          if (el.href) yaml += `  href: "${el.href}"\n`;
          yaml += `  coordinates: [${el.x}, ${el.y}, ${el.width}, ${el.height}]\n`;
          if (i < elements.length - 1) yaml += '\n';
        });
        
        return yaml;
      }
    });
    
    return { snapshot: results[0].result };
  }

  async screenshot(params) {
    // Capture visible tab screenshot
    const dataUrl = await chrome.tabs.captureVisibleTab(
      this.currentTab.windowId,
      { format: 'png' }
    );
    
    return { screenshot: dataUrl };
  }

  async getConsoleLogs(params) {
    // Note: This is simplified - real implementation would need to collect logs over time
    return { logs: ['Console logs would be collected here'] };
  }

  async sendResult(commandId, success, result, error = null) {
    try {
      await fetch(`${this.serverUrl}/browser/result`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          command_id: commandId,
          success,
          result,
          error
        })
      });
    } catch (err) {
      console.error('VectorMCP: Failed to send result:', err);
    }
  }

  stop() {
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
    this.connected = false;
  }
}

// Initialize the client
const vectorMCPClient = new VectorMCPClient();

// Start when extension loads
chrome.runtime.onStartup.addListener(() => {
  console.log('VectorMCP: Extension startup');
  vectorMCPClient.start();
});

chrome.runtime.onInstalled.addListener(() => {
  console.log('VectorMCP: Extension installed');
  vectorMCPClient.start();
});

// Also start immediately when background script loads
console.log('VectorMCP: Background script starting...');
vectorMCPClient.start();

// Handle tab updates
chrome.tabs.onActivated.addListener(async (activeInfo) => {
  const tab = await chrome.tabs.get(activeInfo.tabId);
  vectorMCPClient.currentTab = tab;
});

// Handle messages from popup
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === 'getStatus') {
    sendResponse({
      connected: vectorMCPClient.connected,
      serverUrl: vectorMCPClient.serverUrl,
      currentTab: vectorMCPClient.currentTab?.url
    });
  } else if (request.action === 'toggleConnection') {
    if (vectorMCPClient.connected) {
      vectorMCPClient.stop();
    } else {
      vectorMCPClient.start();
    }
    sendResponse({ success: true });
  }
});

console.log('VectorMCP: Background script loaded');