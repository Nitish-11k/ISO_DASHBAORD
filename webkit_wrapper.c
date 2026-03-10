#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

int main(int argc, char *argv[]) {
    // The executable this wrapper represents (e.g. WebKitWebProcess)
    char *orig_name = argv[0];
    
    // We expect the real executable to be renamed to .real
    char real_path[1024];
    snprintf(real_path, sizeof(real_path), "%s.real", orig_name);
    
    // Setup the hardcoded paths for the bundled loader
    char *loader = "/opt/d-secure-ui/.libs_private/ld-linux-x86-64.so.2";
    char *libs = "/opt/d-secure-ui/.libs_private:/usr/local/lib:/usr/lib:/lib";
    
    // Construct the argument array for the loader
    // argv[0] = loader
    // argv[1] = "--library-path"
    // argv[2] = libs
    // argv[3] = real_path
    // argv[4...] = original arguments from argv[1...]
    char **new_argv = malloc((argc + 4) * sizeof(char *));
    new_argv[0] = loader;
    new_argv[1] = "--library-path";
    new_argv[2] = libs;
    new_argv[3] = real_path;
    
    for (int i = 1; i < argc; i++) {
        new_argv[i + 3] = argv[i];
    }
    new_argv[argc + 3] = NULL;
    
    // Set up the environment
    char **new_envp = malloc(2 * sizeof(char *));
    char env_var[2048];
    snprintf(env_var, sizeof(env_var), "LD_LIBRARY_PATH=%s", libs);
    new_envp[0] = env_var;
    new_envp[1] = NULL;
    
    // Execute the loader directly
    execve(loader, new_argv, new_envp);
    
    // If we reach here, execve failed
    perror("execve failed");
    return 1;
}
