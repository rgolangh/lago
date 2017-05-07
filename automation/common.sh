#!/bin/bash -e
#
# Common functions for the scripts
#


set_guestfs_params() {
    # see: https://bugzilla.redhat.com/show_bug.cgi?id=1404287
    export LIBGUESTFS_APPEND="edd=off"
    # make libguestfs use /dev/shm as tmpdir
    export LIBGUESTFS_CACHEDIR="/dev/shm"
    export LIBGUESTFS_TMPDIR="/dev/shm"

    # ensure KVM is enabled under mock
    ! [[ -c "/dev/kvm" ]] && mknod /dev/kvm c 10 232

    export LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1
}

code_changed() {
    if ! [[ -d .git ]]; then
        echo "Not in a git dir, will run all the tests"
        return 0
    fi
    git diff-tree --no-commit-id --name-only -r HEAD..HEAD^ \
    | grep --quiet -v -e '\(docs/\|README.md\)'
    return $?
}

die() {
    echo "$@"
    exit 1
}

setup_tox() {
    pip install --upgrade pip setuptools virtualenv tox || return 1
}

build_docs() {
    setup_tox
    make docs

}


run_unit_tests() {
    setup_tox
    make check-local
}


run_installation_tests() {
    local yum
    local package
    local res=0
    automation/build-artifacts.sh \
    || return $?
    echo "Installing..."
    if hash dnf &>/dev/null; then
        yum=dnf
    else
        yum=yum
    fi
    # fail if a glob turns out empty
    shopt -s failglob
    for package in {python-,}lago {python-,}lago-ovirt; do
        echo "    $package: installing"
        ## Install one by one to make sure the deps are ok
        $yum install -y exported-artifacts/"$package"-[[:digit:]]*.noarch.rpm \
        && echo "    $package: OK" \
        || {
            echo "    $package: FAILED"
            return 1
        }
        if [[ "$package" == "lago" ]]; then
            echo "    Checking that lago imports are not missing"
            lago -h > /dev/null \
            && echo "    OK" \
            || {
                echo "    FAILED"
                return 1
            }

        elif [[ "$package" == "lago-ovirt" ]]; then
            echo "    Checking that lago ovirt imports are not missing"
            lago ovirt -h > /dev/null \
            && echo "    OK" \
            || {
                echo "    FAILED"
                return 1
            }
        fi
    done
    return $res
}


run_basic_functional_tests() {
    local res
    # Avoid any heavy tests (for example, any that download templates)

    sg lago -c "bats \
        tests/functional/*basic.bats \
        tests/functional/status.bats \
        tests/functional/start.bats \
        tests/functional/collect.bats \
        tests/functional/deploy.bats \
        tests/functional/export.bats" \
    | tee exported-artifacts/functional_tests.tap
    res=${PIPESTATUS[0]}
    return $res
}


run_full_functional_tests() {
    local res
    # Allow notty sudo, for the tests on jenkinslike environment
    [[ -e /etc/sudoers ]] \
    && sed -i -e 's/^Defaults\s*requiretty/Defaults !requiretty/' /etc/sudoers

    sg lago -c 'bats tests/functional/*.bats' \
    | tee exported-artifacts/functional_tests.tap
    res=${PIPESTATUS[0]}
    return $res
}



generate_html_report() {
    cat  >exported-artifacts/index.html <<EOR
    <html>
    <body>
            <li>
                <a href="docs/html/index.html">Docs page</a>
            </li>
EOR
    if code_changed; then
        cat  >>exported-artifacts/index.html <<EOR
            <li>
                <a href="htmlcov/index.html">coverage.py unit tests report</a>
            </li>
            <li>
                <a href="functional_tests.tap">Functional tests result</a>
            </li>

EOR
    fi

    cat  >>exported-artifacts/index.html <<EOR
        </ul>
    </body>
    </html>
EOR
    echo "~ Report at file://$PWD/exported-artifacts/index.html  ~"
}
