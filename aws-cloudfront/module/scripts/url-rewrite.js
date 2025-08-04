function handler(event) {
    var request = event.request;
    var uri = request.uri;
    
    // Base paths configured from Nitric origins
    var basePaths = "${base_paths}".split(',');
    
    // Rewrite logic for API paths
    for (var i = 0; i < basePaths.length; i++) {
        var basePath = basePaths[i];
        if (uri.startsWith(basePath) && basePath !== '/') {
            // Remove the base path for backend routing
            request.uri = uri.substring(basePath.length) || '/';
            break;
        }
    }
    
    return request;
}