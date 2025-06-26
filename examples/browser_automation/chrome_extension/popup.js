// VectorMCP Chrome Extension - Popup Script

document.addEventListener('DOMContentLoaded', function() {
  const statusDiv = document.getElementById('status');
  const statusText = document.getElementById('status-text');
  const serverUrl = document.getElementById('server-url');
  const currentTab = document.getElementById('current-tab');
  const toggleBtn = document.getElementById('toggle-btn');
  const testBtn = document.getElementById('test-btn');

  // Update UI with current status
  function updateStatus() {
    chrome.runtime.sendMessage({ action: 'getStatus' }, function(response) {
      if (response) {
        if (response.connected) {
          statusDiv.className = 'status connected';
          statusText.textContent = 'Connected to VectorMCP';
          toggleBtn.textContent = 'Disconnect';
          toggleBtn.className = 'button secondary';
        } else {
          statusDiv.className = 'status disconnected';
          statusText.textContent = 'Not connected';
          toggleBtn.textContent = 'Connect';
          toggleBtn.className = 'button primary';
        }
        
        serverUrl.textContent = response.serverUrl || 'localhost:8000';
        currentTab.textContent = response.currentTab ? 
          new URL(response.currentTab).hostname : 'No active tab';
      }
    });
  }

  // Toggle connection
  toggleBtn.addEventListener('click', function() {
    chrome.runtime.sendMessage({ action: 'toggleConnection' }, function(response) {
      if (response && response.success) {
        setTimeout(updateStatus, 500); // Give it a moment to connect/disconnect
      }
    });
  });

  // Test connection
  testBtn.addEventListener('click', function() {
    testBtn.textContent = 'Testing...';
    testBtn.disabled = true;
    
    // Try to ping the server directly
    fetch('http://localhost:8000/browser/ping', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ test: true })
    })
    .then(response => {
      if (response.ok) {
        statusText.textContent = 'Server reachable ✓';
        statusDiv.className = 'status connected';
      } else {
        throw new Error(`Server responded with ${response.status}`);
      }
    })
    .catch(error => {
      statusText.textContent = 'Server unreachable ✗';
      statusDiv.className = 'status disconnected';
      console.error('Test failed:', error);
    })
    .finally(() => {
      testBtn.textContent = 'Test Connection';
      testBtn.disabled = false;
      setTimeout(updateStatus, 2000); // Restore actual status
    });
  });

  // Initial status update
  updateStatus();
  
  // Refresh status every 2 seconds
  setInterval(updateStatus, 2000);
});