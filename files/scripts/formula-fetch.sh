#!/bin/bash

# Usage:
#    ./formula-fetch.sh <Formula URL> <Name> <Branch>
#
# Example usage:
#    FORMULA_SOURCES=https://github.com/epcim/my-salt-formulas https://github.com/salt-formulas https://github.com/saltstack-formulas
#    SALT_ENV_PATH=.vendor/formulas
#    --
#    ./formula-fetch.sh
#    xargs -n1 ./formula-fetch.sh < dependencies.txt


## DEFAULTS
#
# default sources
FORMULA_SOURCES="${SALT_FORMULA_SOURCES:-https://github.com/salt-formulas https://github.com/saltstack-formulas}"
FORMULA_VERSION="${SALT_FORMULA_VERSION:-master}"
# salt env/root, where formulas are found
SALT_ENV_PATH=${SALT_ENV_PATH:-/srv/salt/env/prd}
#SALT_ENV_PATH=${SALT_ENV_PATH:-.vendor/formulas}
#SALT_ENV_PATH=${SALT_ENV_PATH:/usr/share/salt-formulas/env/_formulas}
# where to fetch formulas
FORMULAS_BASE=${SALT_FORMULAS_BASE:-/srv/salt/formulas}
# reclass related
RECLASS_BASE=${RECLASS_BASE:-/srv/salt/reclass}
LC_ALL=en_US.UTF-8
LANG=en_US.UTF-8




# Parse git dependencies from metadata.yml
# $1 - path to <formula>/metadata.yml
# sample to output:
#    https://github.com/salt-formulas/salt-formula-git git
#    https://github.com/salt-formulas/salt-formula-salt salt
function fetchDependencies() {
    METADATA="$1";
    grep -E "^dependencies:" "$METADATA" >/dev/null || return 0
    (python - "$METADATA" | while read dep; do fetchGitFormula $dep; done) <<-DEPS
		import sys,yaml
		for dep in yaml.load(open(sys.argv[1], "ro"))["dependencies"]:
		  print("{source} {name}").format(**dep)
		DEPS
}

# Fetch formula from git repo
# $1 - formula git repo url
# $2 - formula name (optional)
# $3 - branch (optional)
function fetchGitFormula() {
    test -n "${FETCHED}" || declare -a FETCHED=()
    mkdir -p "$SALT_ENV_PATH" "$FORMULAS_BASE"

    if [ -n "$1" ]; then

        # set origin uri
        # FIXME, TEMP fix for not yet up to date gh:salt-formulas -> s/tcpcloud/salt-formulas/
        origin="${1/tcpcloud/salt-formulas}"
        # set gh repo https://salt-formulas/salt-formula-salt -> $FORMULAS_BASE/salt-formulas/salt-formula-salt
        repo=$(echo $origin | awk -F'/' '{ print substr($0, index($0,$4)) }')
        # set normula name
        test -n "$2" && name=$2 || name="$(echo $origin | sed -e 's/-formula$//' -e 's/^salt-formula-//' -e 's/^formula-//')"
        # set branch
        test -n "$3" && branch=$3 || branch=${FORMULA_VERSION}

        # DEBUG
        #echo '--- ------------------------------'
        #echo origin, $origin
        #echo repo, $repo
        #echo fetched ${FETCHED[@]}
        #echo name, $name
        ##echo '---'
        #return

        if ! [[ "${FETCHED[*]}" =~ $name ]]; then # dependency not yet fetched
          echo "[I] Fetching: $origin -> $FORMULAS_BASE/$repo"
          if [ -e "$FORMULAS_BASE/$repo" ]; then
              pushd "$FORMULAS_BASE/$repo" &>/dev/null
              git pull -r; git checkout $branch;
              popd &>/dev/null
          else
              echo "[I] git clone $origin $FORMULAS_BASE/$repo -b $branch"
              if ! git ls-remote --exit-code --heads $origin $branch; then
                # Fallback to the master branch if the branch doesn't exist for this repository
                branch=master
              fi
              if ! git clone "$origin" "$FORMULAS_BASE/$repo" -b "$branch"; then
                echo "[E] Fetching formula from $origin failed."
                return ${FAIL_ON_ERRORS:-0}
              fi
          fi

          # metadata.yml is github.com/salt-formulas specific
          if [ ! -n "$name" -a -e  "$FORMULAS_BASE/$repo/metadata.yml" ]; then
            # try to update name as in formula metadata
            name=$(getFormulaName $FORMULAS_BASE/$repo/metadata.yml)
          fi

          # SET FORMULA IN SALT ENV
          if [ ! -e  "$SALT_ENV_PATH/$name" ]; then
            if [ -e $FORMULAS_BASE/$repo/$name ]; then

              # link formula
              ln -svf $FORMULAS_BASE/$repo/$name $SALT_ENV_PATH/$name

              # copy custom _states, _modules, _etc ...
              for c in $(/bin/ls $FORMULAS_BASE/$repo | grep '^_' | xargs -n1 --no-run-if-empty); do
                test -e $SALT_ENV_PATH/$c || mkdir -p $SALT_ENV_PATH/$c
                ln -svf $FORMULAS_BASE/$repo/$c/* $SALT_ENV_PATH/$c
              done

              # install optional dependencies (python/pip related as of now only)
              if [ -e  $FORMULAS_BASE/$repo/requirements.txt ]; then
                pip install -r $FORMULAS_BASE/$repo/requirements.txt
              fi

              # NOTE: github.com/salt-formulas specific steps
              # link formula service pillars
              if [ ! -n "$RECLASS_BASE" -a -e "$FORMULAS_BASE/$repo/metadata/service" ]; then
                test -e $RECLASS_BASE/service || mkdir -p $RECLASS_BASE/service
                ln -svf $FORMULAS_BASE/$repo/metadata/service $RECLASS_BASE/service/$name
              fi
              # install dependencies
              FETCHED+=($name)
              fetchDependencies "$FORMULAS_BASE/$repo/metadata.yml"
            else
              echo "[E] The repository $FORMULAS_BASE/$repo was not recognized as formula repository."
              return ${FAIL_ON_ERRORS:-0}
            fi
          else
            echo "[I] Formula "$name" already fetched."
          fi
        fi
    else
      echo [I] Usage: fetchGitFormula "<git repo>" "[branch]" "[local formula directory name]"
    fi
}

# DEPRECATED, kept for backward compatibility
# for github.com/salt-formulas (linking "service" pillar metadata from formula to reclas classes)
function linkFormulas() {
  # OPTIONAL: Link formulas from git/pkg

  SALT_ROOT=$1
  SALT_ENV=${2:-/usr/share/salt-formulas/env}

  # form git, development versions
  find "$SALT_ENV"/_formulas -maxdepth 1 -mindepth 1 -type d -print0| xargs -0 -n1 --no-run-if-empty basename | xargs -I{} --no-run-if-empty \
    ln -fs "$SALT_ENV"/_formulas/{}/{} "$SALT_ROOT"/{};

  # form pkgs
  find "$SALT_ENV" -maxdepth 1 -mindepth 1 -path "*_formulas*" -prune -o -name "*" -type d -print0| xargs -0 -n1 --no-run-if-empty basename | xargs -I{} --no-run-if-empty \
    ln -fs "$SALT_ENV"/{} "$SALT_ROOT"/{};
}


function getFormulaName() {
  python - "$1" <<-READ_NAME
		import sys,yaml;print yaml.load(open(sys.argv[1], "ro"))["name"]
		READ_NAME
}

function setupPyEnv() {
  pip3 install --upgrade pygithub || {
    which pipenv || {
      pip install --upgrade pipenv
    }
    pipenv --three
    pipenv install pygithub
  }
}

function listRepos_github_com() {
  #export python=$(pipenv --py || (setupPyEnv &>/dev/null; pipenv --py))
  if [ -e Pipfile.lock ]; then python=$(pipenv --py); else python=python3; fi
  $python - "$1" <<-LIST_REPOS
		import sys
		import github
		
		def make_github_agent(user=None, password=None):
		    """ Create github agent to auth """
		    if not user:
		        return github.Github()
		    else:
		        return github.Github(user, password)
		
		def get_org_repos(gh, org_name):
		    org = gh.get_organization(org_name)
		    for repo in org.get_repos():
		        yield repo.name
		
		print(*get_org_repos(make_github_agent(), str(sys.argv[1])), sep="\n")
		LIST_REPOS
}

function fetchAll() {
  for source in $(echo ${FORMULA_SOURCES} | xargs -n1 --no-run-if-empty| xargs -n1 --no-run-if-empty); do
    hosting=$(echo ${source//\./_} | awk -F'/' '{print $3}')
    orgname=$(echo ${source//\./_} | awk -F'/' '{print $4}')
    for repo in $(listRepos_$hosting "$orgname" | xargs -n1 --no-run-if-empty| sort); do
      # TODO, avoid a hardcoded pattern to filter formula repos
      if [[ $repo =~ ^(.*formula.*)$ ]]; then
        fetchGitFormula "$source/$repo";
      fi
    done;
  done;
}

# detect if file is being sourced
[[ "$0" != "$BASH_SOURCE" ]] || {
    # if executed, fetch specific formula
    fetchGitFormula ${@}
}
