// VectorMCP Chrome Extension - Content Script
// This script runs on every page to provide additional DOM access if needed

console.log('VectorMCP: Content script loaded');

// Helper functions that can be called by the background script
window.vectorMCP = {
  // Enhanced element selection with better ARIA support
  findElement: function(selector) {
    // Try multiple selection strategies
    let element = null;
    
    // 1. Standard CSS selector
    if (selector.startsWith('#') || selector.startsWith('.') || selector.includes('[')) {
      element = document.querySelector(selector);
    }
    
    // 2. ARIA label matching
    if (!element && selector.toLowerCase().includes('aria-label')) {
      const ariaValue = selector.match(/aria-label=['"]([^'"]+)['"]/)?.[1];
      if (ariaValue) {
        element = document.querySelector(`[aria-label="${ariaValue}"]`);
      }
    }
    
    // 3. Text content matching
    if (!element) {
      const textElements = document.querySelectorAll('button, a, input[type="submit"], [role="button"]');
      for (const el of textElements) {
        if (el.textContent.trim().toLowerCase().includes(selector.toLowerCase())) {
          element = el;
          break;
        }
      }
    }
    
    return element;
  },

  // Enhanced ARIA snapshot with better accessibility data
  getAriaSnapshot: function() {
    const snapshot = [];
    
    // Get all interactive elements
    const selectors = [
      'input:not([type="hidden"])',
      'button',
      'a[href]',
      'select',
      'textarea',
      '[role="button"]',
      '[role="link"]',
      '[role="textbox"]',
      '[role="searchbox"]',
      '[role="combobox"]',
      '[tabindex]'
    ];
    
    selectors.forEach(selector => {
      document.querySelectorAll(selector).forEach(element => {
        const rect = element.getBoundingClientRect();
        
        // Only include visible elements
        if (rect.width > 0 && rect.height > 0 && 
            rect.top >= 0 && rect.left >= 0 && 
            rect.bottom <= window.innerHeight && 
            rect.right <= window.innerWidth) {
          
          const elementData = {
            tagName: element.tagName.toLowerCase(),
            role: element.getAttribute('role') || this.getImplicitRole(element),
            name: this.getAccessibleName(element),
            value: this.getElementValue(element),
            href: element.href || '',
            id: element.id || '',
            className: element.className || '',
            ariaLabel: element.getAttribute('aria-label') || '',
            placeholder: element.getAttribute('placeholder') || '',
            coordinates: {
              x: Math.round(rect.x),
              y: Math.round(rect.y),
              width: Math.round(rect.width),
              height: Math.round(rect.height),
              centerX: Math.round(rect.x + rect.width / 2),
              centerY: Math.round(rect.y + rect.height / 2)
            },
            visible: true,
            enabled: !element.disabled
          };
          
          snapshot.push(elementData);
        }
      });
    });
    
    return snapshot;
  },

  // Get implicit ARIA role for an element
  getImplicitRole: function(element) {
    const tagName = element.tagName.toLowerCase();
    
    switch (tagName) {
      case 'input':
        const type = element.type.toLowerCase();
        if (type === 'button' || type === 'submit') return 'button';
        if (type === 'text' || type === 'email' || type === 'password') return 'textbox';
        if (type === 'search') return 'searchbox';
        return 'textbox';
      case 'button':
        return 'button';
      case 'a':
        return element.href ? 'link' : 'generic';
      case 'select':
        return 'combobox';
      case 'textarea':
        return 'textbox';
      default:
        return 'generic';
    }
  },

  // Get accessible name using ARIA naming computation
  getAccessibleName: function(element) {
    // 1. aria-label
    if (element.getAttribute('aria-label')) {
      return element.getAttribute('aria-label');
    }
    
    // 2. aria-labelledby
    const labelledBy = element.getAttribute('aria-labelledby');
    if (labelledBy) {
      const labelElement = document.getElementById(labelledBy);
      if (labelElement) {
        return labelElement.textContent.trim();
      }
    }
    
    // 3. Associated label
    if (element.id) {
      const label = document.querySelector(`label[for="${element.id}"]`);
      if (label) {
        return label.textContent.trim();
      }
    }
    
    // 4. Placeholder
    if (element.getAttribute('placeholder')) {
      return element.getAttribute('placeholder');
    }
    
    // 5. Text content (for buttons, links)
    if (['button', 'a'].includes(element.tagName.toLowerCase())) {
      return element.textContent.trim();
    }
    
    // 6. Value (for inputs)
    if (element.value) {
      return element.value;
    }
    
    return '';
  },

  // Get element value
  getElementValue: function(element) {
    if (element.value !== undefined) {
      return element.value;
    }
    
    if (element.textContent) {
      return element.textContent.trim();
    }
    
    return '';
  },

  // Simulate typing with proper events
  simulateTyping: function(element, text) {
    element.focus();
    
    // Clear existing value
    element.value = '';
    
    // Simulate typing character by character
    for (let i = 0; i < text.length; i++) {
      const char = text[i];
      
      // Key events
      element.dispatchEvent(new KeyboardEvent('keydown', { key: char, bubbles: true }));
      element.dispatchEvent(new KeyboardEvent('keypress', { key: char, bubbles: true }));
      
      // Update value
      element.value += char;
      
      // Input event
      element.dispatchEvent(new Event('input', { bubbles: true }));
      
      element.dispatchEvent(new KeyboardEvent('keyup', { key: char, bubbles: true }));
    }
    
    // Final change event
    element.dispatchEvent(new Event('change', { bubbles: true }));
  },

  // Enhanced click simulation
  simulateClick: function(element) {
    const rect = element.getBoundingClientRect();
    const centerX = rect.left + rect.width / 2;
    const centerY = rect.top + rect.height / 2;
    
    // Mouse events
    element.dispatchEvent(new MouseEvent('mousedown', {
      bubbles: true,
      clientX: centerX,
      clientY: centerY
    }));
    
    element.dispatchEvent(new MouseEvent('mouseup', {
      bubbles: true,
      clientX: centerX,
      clientY: centerY
    }));
    
    element.dispatchEvent(new MouseEvent('click', {
      bubbles: true,
      clientX: centerX,
      clientY: centerY
    }));
    
    // Focus if focusable
    if (element.focus) {
      element.focus();
    }
  }
};

// Notify background script that content script is ready
chrome.runtime.sendMessage({ action: 'contentScriptReady' });