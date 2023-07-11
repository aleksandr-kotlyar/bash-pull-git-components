### When you need it
When you have more than one repository you need to pull and setup to directed commit repeatedly

### How it works 
Script pulls list of your git components from file and checkout them to directed commits/branches

### How to use
1. Open pull.sh
2. Uncomment git block and set your git_path and setup ssh/oauth tokens
3. Create components.json with repo name as a key and commit as a value, empty string "" means master will be default
4. [Run script](run-example)
5. You can set main instead of master as default branch by changing script
6. You can use any filetype to host `repo:commit` textfile, yamlfile, whatever you want and adopt script for parsing it 
7. Also, you can use git submodules instead of this solution

### Run example
```
sh pull.sh ./examples/components.json
```

Cheers!