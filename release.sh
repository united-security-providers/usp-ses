#!/bin/bash

set -eE # same as: `set -o errexit -o errtrace`
trap 'catch $? $LINENO' ERR

catch() {
  echo "Error $1 occurred on line $2"
}

checkbin() {
  local cmd=$1
  if ! command -v $cmd &> /dev/null; then
    echo "$cmd command could not be found"
    exit
  fi
}

downloadFromNexus() {
  local version=$1
  local groupId=$2
  local artifactId=$3
  local type=$4
  local classifier=$5

  local repository='releases'
  if [[ $version =~ "SNAPSHOT" ]]; then
    repository='snapshots'
  fi

  local query="http://nexus-bob.u-s-p.local/service/rest/v1/search/assets?sort=version&maven.baseVersion=$version&maven.groupId=$groupId&maven.artifactId=$artifactId&maven.extension=$type&maven.classifier=$classifier"
  echo "Nexus query: $query"

  wget -O info.json $query
  downloadUrl=`cat info.json | grep -v '\-sources' | grep -a -m 1 -h "downloadUrl" | grep -Po 'downloadUrl" : "\K[^"]*'`
  rm info.json

  if [[ -z "$classifier" ]]; then
    filename=$artifactId-$version.$type
  else
    filename=$artifactId-$version-$classifier.$type
  fi

  wget -O $filename $downloadUrl
  if [[ "$type" == "zip" || "$type" == "jar" ]]; then
    jar xvf $filename
  fi
}

checkbin mkdocs
checkbin wget

if [ "$#" -lt 1 ]
then
  echo "Not enough arguments supplied. Usage:"
  echo ""
  echo "./release.sh <ses version, e.g. 5.18.0.1> [deploy]"
  echo ""
  echo "If the optional 'deploy' argument is set, the website will be deployed to Github and made public!"
  echo ""
  echo "Example for creating the website without deployment:"
  echo ""
  echo "./release.sh 5.18.0.1"
  exit 1
fi

# 1st input parameter = Core Authenticate container version (equals SLS version)
export SES_VERSION=$1

DIR=`pwd`
rm -rf build
rm -rf docs
rm -rf generated
mkdir build
cd build

echo "-------------------------------------------------------------"
echo "Selected Secure Entry Server release: $SES_VERSION"
echo "-------------------------------------------------------------"

curl -k "https://appliance-builder.u-s-p.local/deliveries/index.json" -o index.json

CMD='. | map(select(.version == "'${SES_VERSION}'"))'
RELEASE_JSON=$(cat index.json | jq "$CMD")
PACKAGES=$(echo ${RELEASE_JSON} | jq ".[0].files.packages" | tr -d '"')
PACKAGES_URL="https://appliance-builder.u-s-p.local/deliveries/ses/${SES_VERSION}/final/${SES_VERSION}/${PACKAGES}"

curl -k $PACKAGES_URL -o packages.txt

SLS_ENTRY=$(cat packages.txt | grep "net-misc/usp-sls-doc")
SLS_VERSION=$(echo $SLS_ENTRY | cut -d "-" -f 5)

HSP_ENTRY=$(cat packages.txt | grep "net-misc/usp-hsp-doc")
HSP_VERSION=$(echo $HSP_ENTRY | cut -d "-" -f 5)

echo "SLS Version: $SLS_VERSION"
echo "HSP Version: $HSP_VERSION"

# ======================================
# SES appliance documentation
# ======================================
mkdir ses-docs
cd ses-docs
downloadFromNexus $SES_VERSION com.usp.ses ses-appliance-doc tar.bz2
bunzip2 *.*
tar xf *.*
rm -f *.tar
downloadFromNexus $SES_VERSION com.usp.ses ses-release-notes jar
mv ses-$SES_VERSION.md releasenotes.md
downloadFromNexus $SES_VERSION com.usp.ses ses-appliance-whatsnew jar
curl -k -L https://github.com/suntong/html2md/releases/download/v1.6.0/html2md_1.6.0_linux_amd64.tar.gz -o html2md.tar.gz
tar xzf html2md.tar.gz
HTML2MD=$(find . -type f -name html2md)
$HTML2MD -i whats_new.html > whats_new.md
cd ..

# ======================================
# SLS documentation
# ======================================
mkdir sls-docs
cd sls-docs
# Download generated docs bundle (PDFs and HTML)
downloadFromNexus $SLS_VERSION com.usp.sls.framework sls-generated-docs zip docs
rm -f *.zip
cd ..

# ======================================
# HSP documentation
# ======================================
mkdir hsp-docs
cd hsp-docs
downloadFromNexus $HSP_VERSION com.usp.hsp hsp-docs tar.bz2
bunzip2 *.*
tar xf *.*
rm -f *.tar

# =====================================================================
# Begin site build
# =====================================================================

# Prepare site source directory
cd $DIR

# Copy base markdown files from sources
cp -R src/docs ./docs

mkdir -p ./docs/files
cp -r ./build/sls-docs/* ./docs/files/
cp -r ./build/hsp-docs/* ./docs/files/
cp -r ./build/ses-docs/* ./docs/files/

# Replace version placeholders in all markdown files
for file in ./docs/*; do
    if [ -f "$file" ]; then
        sed -i -e 's/%HSP_VERSION%/'$HSP_VERSION'/g' $file
        sed -i -e 's/%SLS_VERSION%/'$SLS_VERSION'/g' $file
        sed -i -e 's/%SES_VERSION%/'$SES_VERSION'/g' $file
    fi
done

echo "Successfully generated site (Markdown) at ./docs."

VERSION=$(echo "$1" | sed -E 's/^v?([0-9]+)\.([0-9]+)\.([0-9]+)\.[0-9]+$/\1.\2.x/')

[ "$2" == "deploy" ] && DEPLOY=true && shift
[ "$2" == "--latest" ] && RELEASE_ALIAS=latest && shift

if [ $DEPLOY ]; then
    echo "Deploying to GitHub pages..."
    mike deploy --update-aliases --push "${VERSION}" $RELEASE_ALIAS
#    mkdocs gh-deploy --force
    echo "Successfully deployed to to GitHub pages"
    git tag -f ${VERSION}
    git push -f --tags
fi

if [[ $DEPLOY && "${RELEASE_ALIAS}" == "latest" ]]; then
    echo "Setting default latest..."
    sleep 60
    mike set-default --push --allow-empty "${RELEASE_ALIAS}"
    echo "Set default latest."
fi

trap - ERR
