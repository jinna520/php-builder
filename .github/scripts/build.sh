setup_phpbuild() {
  (
    cd ~ || exit
    git clone git://github.com/php-build/php-build
    cd php-build || exit
    sudo ./install.sh
    if [ "$new_version" != "nightly" ]; then
      sudo cp "$action_dir"/.github/scripts/stable /usr/local/share/php-build/definitions/"$PHP_VERSION"
      sudo sed -i "s/phpsrctag/$new_version/" /usr/local/share/php-build/definitions/"$PHP_VERSION"
    else
      sudo cp "$action_dir"/.github/scripts/"$PHP_VERSION" /usr/local/share/php-build/definitions/
    fi
  )
}

setup_pear() {
  sudo curl -fsSL --retry "$tries" -o /usr/local/ssl/cert.pem https://curl.haxx.se/ca/cacert.pem
  sudo curl -fsSL --retry "$tries" -O https://pear.php.net/go-pear.phar
  sudo chmod a+x .github/scripts/install-pear.expect
  .github/scripts/install-pear.expect "$install_dir"
  rm go-pear.phar
  sudo "$install_dir"/bin/pear config-set php_ini "$install_dir"/etc/php.ini system
  sudo "$install_dir"/bin/pear channel-update pear.php.net
}

setup_coverage() {
  sudo "$install_dir"/bin/pecl install -f pcov
  sudo sed -i "/pcov/d" "$install_dir"/etc/php.ini
  sudo chmod a+x .github/scripts/install-ext-master.sh
  .github/scripts/install-ext-master.sh xdebug xdebug/xdebug "$install_dir" --enable-xdebug
  .github/scripts/install-ext-master.sh imagick Imagick/imagick "$install_dir"
}

build_php() {
  if ! php-build -v -i production "$PHP_VERSION" "$install_dir"; then
    echo 'Failed to build PHP'
    exit 1
  fi

  sudo chmod 777 "$install_dir"/etc/php.ini
  (
    echo "date.timezone=UTC"
    echo "memory_limit=-1"
  ) >>"$install_dir"/etc/php.ini
  setup_pear
  setup_coverage
  sudo ln -sv "$install_dir"/sbin/php-fpm "$install_dir"/bin/php-fpm
  sudo ln -sf "$install_dir"/bin/* /usr/bin/
  sudo ln -sf "$install_dir"/etc/php.ini /etc/php.ini
}

bintray_create_package() {
  curl \
  --user "$BINTRAY_USER":"$BINTRAY_KEY" \
  --header "Content-Type: application/json" \
  --data " \
{\"name\": \"$PHP_VERSION-linux\", \
\"vcs_url\": \"$GITHUB_REPOSITORY\", \
\"licenses\": [\"MIT\"], \
\"public_download_numbers\": true, \
\"public_stats\": true \
}" \
  https://api.bintray.com/packages/"$BINTRAY_USER"/"$BINTRAY_REPO" || true
}

build_and_ship() {
  (
    curl -sSLO http://archive.ubuntu.com/ubuntu/pool/main/g/gcc-10/gcc-10-base_10-20200411-0ubuntu1_amd64.deb
    curl -sSLO http://archive.ubuntu.com/ubuntu/pool/main/g/gcc-10/libgcc-s1_10-20200411-0ubuntu1_amd64.deb
    curl -sSLO http://archive.ubuntu.com/ubuntu/pool/universe/libz/libzstd/zstd_1.4.4+dfsg-3_amd64.deb
    sudo DEBIAN_FRONTEND=noninteractive dpkg -i --force-conflicts ./*.deb
    rm -rf ./*.deb
    zstd -V
    cd "$install_dir"/.. || exit
    sudo XZ_OPT=-e9 tar cfJ php_"$PHP_VERSION"+ubuntu"$release".tar.xz "$PHP_VERSION"
    sudo tar cf - "$PHP_VERSION" | zstd -22 -T0 --ultra > php_"$PHP_VERSION"+ubuntu"$release".tar.zst
    curl --user "$BINTRAY_USER":"$BINTRAY_KEY" -X DELETE https://api.bintray.com/content/"$BINTRAY_USER"/"$BINTRAY_REPO"/php_"$PHP_VERSION"+ubuntu"$release".tar.xz || true
    curl --user "$BINTRAY_USER":"$BINTRAY_KEY" -X DELETE https://api.bintray.com/content/"$BINTRAY_USER"/"$BINTRAY_REPO"/php_"$PHP_VERSION"+ubuntu"$release".tar.zst || true
    curl --user "$BINTRAY_USER":"$BINTRAY_KEY" -T php_"$PHP_VERSION"+ubuntu"$release".tar.xz https://api.bintray.com/content/shivammathur/php/"$PHP_VERSION"-linux/"$PHP_VERSION"+ubuntu"$release"/php_"$PHP_VERSION"+ubuntu"$release".tar.xz || true
    curl --user "$BINTRAY_USER":"$BINTRAY_KEY" -T php_"$PHP_VERSION"+ubuntu"$release".tar.zst https://api.bintray.com/content/shivammathur/php/"$PHP_VERSION"-linux/"$PHP_VERSION"+ubuntu"$release"/php_"$PHP_VERSION"+ubuntu"$release".tar.zst || true
    curl --user "$BINTRAY_USER":"$BINTRAY_KEY" -X POST https://api.bintray.com/content/"$BINTRAY_USER"/"$BINTRAY_REPO"/"$PHP_VERSION"-linux/"$PHP_VERSION"+ubuntu"$release"/publish || true
  )
}

check_stable() {
  if [ "$new_version" = "$existing_version" ]; then
    (
      cd "$install_dir"/.. || exit
      sudo curl -fSL --retry "$tries" -O https://dl.bintray.com/shivammathur/php/php_"$PHP_VERSION"+ubuntu"$release".tar.xz
      sudo curl -fSL --retry "$tries" -O https://dl.bintray.com/shivammathur/php/php_"$PHP_VERSION"+ubuntu"$release".tar.zst
      ls -la
    )
    echo "$new_version" exists
    exit 0
  fi
  if [ "$new_version" = "" ]; then
    new_version='nightly'
  fi
}

release=$(lsb_release -r -s)
install_dir=/usr/local/php/"$PHP_VERSION"
action_dir=$(pwd)
tries=10
existing_version=$(curl -sL https://github.com/shivammathur/php-builder/releases/latest/download/php"$PHP_VERSION".log)
new_version=$(curl -sL https://api.github.com/repos/php/php-src/git/refs/tags | grep -Po "php-$PHP_VERSION.[0-9]+" | tail -n 1)
sudo mkdir -p "$install_dir" /usr/local/ssl
sudo chmod -R 777 /usr/local/php /usr/local/ssl
check_stable
setup_phpbuild
build_php
bintray_create_package
build_and_ship
