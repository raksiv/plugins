// API base URL - in production this would be the CloudFront domain
const API_BASE = '/api';

// Helper function to display results
function displayResult(elementId, data, isError = false) {
    const element = document.getElementById(elementId);
    const className = isError ? 'error' : 'success';
    const timestamp = new Date().toLocaleTimeString();
    
    element.innerHTML = `
        <div class="${className}">
            [${timestamp}] ${isError ? 'ERROR' : 'SUCCESS'}
        </div>
        <pre>${JSON.stringify(data, null, 2)}</pre>
    `;
}

// Test health check endpoint
async function testHealth() {
    try {
        const response = await fetch(`${API_BASE}/health`);
        const data = await response.json();
        displayResult('api-results', data);
    } catch (error) {
        displayResult('api-results', { error: error.message }, true);
    }
}

// List files in uploads bucket
async function listFiles() {
    try {
        const response = await fetch(`${API_BASE}/files`);
        const data = await response.json();
        displayResult('api-results', data);
    } catch (error) {
        displayResult('api-results', { error: error.message }, true);
    }
}

// Upload test file
async function uploadTest() {
    try {
        const testData = {
            filename: `test-${Date.now()}.txt`,
            content: btoa(`Hello from Nitric! Timestamp: ${new Date().toISOString()}`)
        };

        const response = await fetch(`${API_BASE}/upload`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(testData)
        });

        const data = await response.json();
        displayResult('api-results', data, !response.ok);
    } catch (error) {
        displayResult('api-results', { error: error.message }, true);
    }
}

// Upload user-selected file
async function uploadFile() {
    const fileInput = document.getElementById('fileInput');
    const file = fileInput.files[0];
    
    if (!file) {
        displayResult('upload-results', { error: 'Please select a file first' }, true);
        return;
    }

    try {
        // Convert file to base64
        const reader = new FileReader();
        reader.onload = async function(e) {
            const base64Content = e.target.result.split(',')[1]; // Remove data:type;base64, prefix
            
            const uploadData = {
                filename: file.name,
                content: base64Content
            };

            const response = await fetch(`${API_BASE}/upload`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify(uploadData)
            });

            const data = await response.json();
            displayResult('upload-results', data, !response.ok);
            
            // Clear file input
            fileInput.value = '';
        };
        
        reader.readAsDataURL(file);
    } catch (error) {
        displayResult('upload-results', { error: error.message }, true);
    }
}

// Show welcome message on load
document.addEventListener('DOMContentLoaded', function() {
    displayResult('api-results', { 
        message: 'Ready to test your Nitric AWS plugin library!',
        info: 'Click the buttons above to test the API endpoints'
    });
});