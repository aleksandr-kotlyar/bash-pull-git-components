pull_components() {
  components=$(sed -nE 's/[[:space:]",]//gp' $1) # could use -r instead of -E
  for component in $components
  do
    echo "$component"
    IFS=: read -r left right <<< "$component"
    echo $left
    echo $right
#    git clone git_path/${left}.git
#    cd $left
#    git checkout $right || git checkout master
#    cd ..
  done
}
pull_components $1