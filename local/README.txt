-- git
git add --all
git commit -am "[#22] <commit message>"
git push

git fetch --all
git reset --hard origin/master

git commit --amend -m "Replace commit message"


git tag -a 1.0.5 -m 'pago electronico'
git push --tags

# Lista todas las branches
git branch -a 
