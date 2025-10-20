function kmkssh(){
  if [ "$(date +%s)" -gt "$(date -d "$(ssh-add -L | grep cert |grep vaultssh | head -n1 | ssh-keygen -L -f /dev/stdin | grep Valid |awk '{print $5}')" +%s)" ]; then
     kmk 
  fi
  ssh $@
}
