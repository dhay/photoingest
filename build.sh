#!/bin/sh

canonpath() { 
  if [ -d $1 ]; then
    echo $(cd $1; pwd -P)
  else
    echo $(cd $(dirname $1); pwd -P)/$(basename $1)
  fi
}


project_basedir=$(canonpath $(dirname $0))
project_build_dir=${project_basedir}/target
project_src_dir=${project_basedir}/src/main

usage() {
  cat <<-END >&2
Usage: $(basename $0) [options]
  -c         Cleanup before building
  -f <file>  Specify an alternate configuration file
  -h         Display this help message
END
}

clean() {
  echo "Deleting directory ${project_build_dir}"
  rm -rf ${project_build_dir}
}

filter() {
  sed "s/_@@_BUILD_VERSION_@@_/${BUILD_VERSION}/g" $1
}

package() {
  archive_basedir="photoingest-${BUILD_VERSION}"
  archive_dir="${project_build_dir}/${archive_basedir}"

  echo "Assembling archive in ${archive_dir}";

  mkdir -p  $archive_dir
  CP="cp -f"
  for f in ${project_src_dir}/perl/*; do
    filter $f > ${archive_dir}/$(basename $f);
  done
  ${CP} ${project_basedir}/LICENSE* ${archive_dir}
#  ${CP} ${project_basedir}/README* ${archive_dir}

  tar_file=${project_build_dir}/${archive_basedir}.tar.gz

  echo "Generating tar ${tar_file}"
  tar -zcf ${tar_file} -C ${project_build_dir} ${archive_basedir}

  zip_file=${project_build_dir}/${archive_basedir}.zip

  echo "Generating zip ${zip_file}"
  (cd ${project_build_dir} && zip -qr ${zip_file} ${archive_basedir})
}

opt_package=0
opt_clean=0
conf=${project_basedir}/build.conf
while getopts cpf:h arg; do
  case $arg in
    c) opt_clean=1 ;;
    f) conf=$OPTARG ;;
    p) opt_package=1 ;;
    h|?) usage; exit 1 ;;
  esac
done

source ${conf}

if [ $opt_clean   -eq 1 ]; then clean;   fi
if [ $opt_package -eq 1 ]; then package; fi

echo "Finished at: $(date)"
