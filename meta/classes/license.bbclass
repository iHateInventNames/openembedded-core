# Populates LICENSE_DIRECTORY as set in distro config with the license files as set by
# LIC_FILES_CHKSUM.
# TODO:
# - There is a real issue revolving around license naming standards.

LICENSE_DIRECTORY ??= "${DEPLOY_DIR}/licenses"
LICSSTATEDIR = "${WORKDIR}/license-destdir/"

# Create extra package with license texts and add it to RRECOMMENDS_${PN}
LICENSE_CREATE_PACKAGE[type] = "boolean"
LICENSE_CREATE_PACKAGE ??= "0"
LICENSE_PACKAGE_SUFFIX ??= "-lic"
LICENSE_FILES_DIRECTORY ??= "${datadir}/licenses/"

addtask populate_lic after do_patch before do_build
do_populate_lic[dirs] = "${LICSSTATEDIR}/${PN}"
do_populate_lic[cleandirs] = "${LICSSTATEDIR}"

python write_package_manifest() {
    # Get list of installed packages
    license_image_dir = d.expand('${LICENSE_DIRECTORY}/${IMAGE_NAME}')
    bb.utils.mkdirhier(license_image_dir)
    from oe.rootfs import image_list_installed_packages
    open(os.path.join(license_image_dir, 'package.manifest'),
        'w+').write(image_list_installed_packages(d))
}

python license_create_manifest() {
    import re
    import oe.packagedata
    from oe.rootfs import image_list_installed_packages

    bad_licenses = (d.getVar("INCOMPATIBLE_LICENSE", True) or "").split()
    bad_licenses = map(lambda l: canonical_license(d, l), bad_licenses)
    bad_licenses = expand_wildcard_licenses(d, bad_licenses)

    build_images_from_feeds = d.getVar('BUILD_IMAGES_FROM_FEEDS', True)
    if build_images_from_feeds == "1":
        return 0

    pkg_dic = {}
    for pkg in image_list_installed_packages(d).split("\n"):
        pkg_info = os.path.join(d.getVar('PKGDATA_DIR', True),
                                'runtime-reverse', pkg)
        pkg_name = os.path.basename(os.readlink(pkg_info))

        pkg_dic[pkg_name] = oe.packagedata.read_pkgdatafile(pkg_info)
        if not "LICENSE" in pkg_dic[pkg_name].keys():
            pkg_lic_name = "LICENSE_" + pkg_name
            pkg_dic[pkg_name]["LICENSE"] = pkg_dic[pkg_name][pkg_lic_name]

    license_manifest = os.path.join(d.getVar('LICENSE_DIRECTORY', True),
                        d.getVar('IMAGE_NAME', True), 'license.manifest')
    with open(license_manifest, "w") as license_file:
        for pkg in sorted(pkg_dic):
            if bad_licenses:
                try:
                    (pkg_dic[pkg]["LICENSE"], pkg_dic[pkg]["LICENSES"]) = \
                        oe.license.manifest_licenses(pkg_dic[pkg]["LICENSE"],
                        bad_licenses, canonical_license, d)
                except oe.license.LicenseError as exc:
                    bb.fatal('%s: %s' % (d.getVar('P', True), exc))
            else:
                pkg_dic[pkg]["LICENSES"] = re.sub('[|&()*]', '', pkg_dic[pkg]["LICENSE"])
                pkg_dic[pkg]["LICENSES"] = re.sub('  *', ' ', pkg_dic[pkg]["LICENSES"])
                pkg_dic[pkg]["LICENSES"] = pkg_dic[pkg]["LICENSES"].split()

            license_file.write("PACKAGE NAME: %s\n" % pkg)
            license_file.write("PACKAGE VERSION: %s\n" % pkg_dic[pkg]["PV"])
            license_file.write("RECIPE NAME: %s\n" % pkg_dic[pkg]["PN"])
            license_file.write("LICENSE: %s\n\n" % pkg_dic[pkg]["LICENSE"])

            # If the package doesn't contain any file, that is, its size is 0, the license
            # isn't relevant as far as the final image is concerned. So doing license check
            # doesn't make much sense, skip it.
            if pkg_dic[pkg]["PKGSIZE_%s" % pkg] == "0":
                continue

            for lic in pkg_dic[pkg]["LICENSES"]:
                lic_file = os.path.join(d.getVar('LICENSE_DIRECTORY', True),
                                        pkg_dic[pkg]["PN"], "generic_%s" % 
                                        re.sub('\+', '', lic))
                if not os.path.exists(lic_file):
                   bb.warn("The license listed %s was not in the "\ 
                            "licenses collected for recipe %s" 
                            % (lic, pkg_dic[pkg]["PN"]))

    # Two options here:
    # - Just copy the manifest
    # - Copy the manifest and the license directories
    # With both options set we see a .5 M increase in core-image-minimal
    copy_lic_manifest = d.getVar('COPY_LIC_MANIFEST', True)
    copy_lic_dirs = d.getVar('COPY_LIC_DIRS', True)
    if copy_lic_manifest == "1":
        rootfs_license_dir = os.path.join(d.getVar('IMAGE_ROOTFS', 'True'), 
                                'usr', 'share', 'common-licenses')
        os.makedirs(rootfs_license_dir)
        rootfs_license_manifest = os.path.join(rootfs_license_dir,
                                                'license.manifest')
        os.link(license_manifest, rootfs_license_manifest)

        if copy_lic_dirs == "1":
            for pkg in sorted(pkg_dic):
                pkg_rootfs_license_dir = os.path.join(rootfs_license_dir, pkg)
                os.makedirs(pkg_rootfs_license_dir)
                pkg_license_dir = os.path.join(d.getVar('LICENSE_DIRECTORY', True),
                                            pkg_dic[pkg]["PN"]) 
                licenses = os.listdir(pkg_license_dir)
                for lic in licenses:
                    rootfs_license = os.path.join(rootfs_license_dir, lic)
                    pkg_license = os.path.join(pkg_license_dir, lic)
                    pkg_rootfs_license = os.path.join(pkg_rootfs_license_dir, lic)

                    if re.match("^generic_.*$", lic):
                        generic_lic = re.search("^generic_(.*)$", lic).group(1)
                        if oe.license.license_ok(canonical_license(d,
                            generic_lic), bad_licenses) == False:
                            continue

                        if not os.path.exists(rootfs_license):
                            os.link(pkg_license, rootfs_license)

                        os.symlink(os.path.join('..', lic), pkg_rootfs_license)
                    else:
                        if oe.license.license_ok(canonical_license(d,
                            lic), bad_licenses) == False:
                            continue

                        os.link(pkg_license, pkg_rootfs_license)
}

python do_populate_lic() {
    """
    Populate LICENSE_DIRECTORY with licenses.
    """
    lic_files_paths = find_license_files(d)

    # The base directory we wrangle licenses to
    destdir = os.path.join(d.getVar('LICSSTATEDIR', True), d.getVar('PN', True))
    copy_license_files(lic_files_paths, destdir)
}

# it would be better to copy them in do_install_append, but find_license_filesa is python
python perform_packagecopy_prepend () {
    enabled = oe.data.typed_value('LICENSE_CREATE_PACKAGE', d)
    if d.getVar('CLASSOVERRIDE', True) == 'class-target' and enabled:
        lic_files_paths = find_license_files(d)

        # LICENSE_FILES_DIRECTORY starts with '/' so os.path.join cannot be used to join D and LICENSE_FILES_DIRECTORY
        destdir = d.getVar('D', True) + os.path.join(d.getVar('LICENSE_FILES_DIRECTORY', True), d.getVar('PN', True))
        copy_license_files(lic_files_paths, destdir)
        add_package_and_files(d)
}

def add_package_and_files(d):
    packages = d.getVar('PACKAGES', True)
    files = d.getVar('LICENSE_FILES_DIRECTORY', True)
    pn = d.getVar('PN', True)
    pn_lic = "%s%s" % (pn, d.getVar('LICENSE_PACKAGE_SUFFIX'))
    if pn_lic in packages:
        bb.warn("%s package already existed in %s." % (pn_lic, pn))
    else:
        # first in PACKAGES to be sure that nothing else gets LICENSE_FILES_DIRECTORY
        d.setVar('PACKAGES', "%s %s" % (pn_lic, packages))
        d.setVar('FILES_' + pn_lic, files)
        rrecommends_pn = d.getVar('RRECOMMENDS_' + pn, True)
        if rrecommends_pn:
            d.setVar('RRECOMMENDS_' + pn, "%s %s" % (pn_lic, rrecommends_pn))
        else:
            d.setVar('RRECOMMENDS_' + pn, "%s" % (pn_lic))

def copy_license_files(lic_files_paths, destdir):
    import shutil

    bb.utils.mkdirhier(destdir)
    for (basename, path) in lic_files_paths:
        try:
            src = path
            dst = os.path.join(destdir, basename)
            if os.path.exists(dst):
                os.remove(dst)
            if os.access(src, os.W_OK) and (os.stat(src).st_dev == os.stat(destdir).st_dev):
                os.link(src, dst)
            else:
                shutil.copyfile(src, dst)
        except Exception as e:
            bb.warn("Could not copy license file %s to %s: %s" % (src, dst, e))

def find_license_files(d):
    """
    Creates list of files used in LIC_FILES_CHKSUM and generic LICENSE files.
    """
    import shutil
    import oe.license

    pn = d.getVar('PN', True)
    for package in d.getVar('PACKAGES', True):
        if d.getVar('LICENSE_' + package, True):
            license_types = license_types + ' & ' + \
                            d.getVar('LICENSE_' + package, True)

    #If we get here with no license types, then that means we have a recipe 
    #level license. If so, we grab only those.
    try:
        license_types
    except NameError:        
        # All the license types at the recipe level
        license_types = d.getVar('LICENSE', True)
 
    # All the license files for the package
    lic_files = d.getVar('LIC_FILES_CHKSUM', True)
    pn = d.getVar('PN', True)
    # The license files are located in S/LIC_FILE_CHECKSUM.
    srcdir = d.getVar('S', True)
    # Directory we store the generic licenses as set in the distro configuration
    generic_directory = d.getVar('COMMON_LICENSE_DIR', True)
    # List of basename, path tuples
    lic_files_paths = []
    license_source_dirs = []
    license_source_dirs.append(generic_directory)
    try:
        additional_lic_dirs = d.getVar('LICENSE_PATH', True).split()
        for lic_dir in additional_lic_dirs:
            license_source_dirs.append(lic_dir)
    except:
        pass

    class FindVisitor(oe.license.LicenseVisitor):
        def visit_Str(self, node):
            #
            # Until I figure out what to do with
            # the two modifiers I support (or greater = +
            # and "with exceptions" being *
            # we'll just strip out the modifier and put
            # the base license.
            find_license(node.s.replace("+", "").replace("*", ""))
            self.generic_visit(node)

    def find_license(license_type):
        try:
            bb.utils.mkdirhier(gen_lic_dest)
        except:
            pass
        spdx_generic = None
        license_source = None
        # If the generic does not exist we need to check to see if there is an SPDX mapping to it,
        # unless NO_GENERIC_LICENSE is set.

        for lic_dir in license_source_dirs:
            if not os.path.isfile(os.path.join(lic_dir, license_type)):
                if d.getVarFlag('SPDXLICENSEMAP', license_type) != None:
                    # Great, there is an SPDXLICENSEMAP. We can copy!
                    bb.debug(1, "We need to use a SPDXLICENSEMAP for %s" % (license_type))
                    spdx_generic = d.getVarFlag('SPDXLICENSEMAP', license_type)
                    license_source = lic_dir
                    break
            elif os.path.isfile(os.path.join(lic_dir, license_type)):
                spdx_generic = license_type
                license_source = lic_dir
                break

        if spdx_generic and license_source:
            # we really should copy to generic_ + spdx_generic, however, that ends up messing the manifest
            # audit up. This should be fixed in emit_pkgdata (or, we actually got and fix all the recipes)

            lic_files_paths.append(("generic_" + license_type, os.path.join(license_source, spdx_generic)))

            # The user may attempt to use NO_GENERIC_LICENSE for a generic license which doesn't make sense
            # and should not be allowed, warn the user in this case.
            if d.getVarFlag('NO_GENERIC_LICENSE', license_type):
                bb.warn("%s: %s is a generic license, please don't use NO_GENERIC_LICENSE for it." % (pn, license_type))

        elif d.getVarFlag('NO_GENERIC_LICENSE', license_type):
            # if NO_GENERIC_LICENSE is set, we copy the license files from the fetched source
            # of the package rather than the license_source_dirs.
            for (basename, path) in lic_files_paths:
                if d.getVarFlag('NO_GENERIC_LICENSE', license_type) == basename:
                    lic_files_paths.append(("generic_" + license_type, path))
                    break
        else:
            # And here is where we warn people that their licenses are lousy
            bb.warn("%s: No generic license file exists for: %s in any provider" % (pn, license_type))
            pass

    if not generic_directory:
        raise bb.build.FuncFailed("COMMON_LICENSE_DIR is unset. Please set this in your distro config")

    if not lic_files:
        # No recipe should have an invalid license file. This is checked else
        # where, but let's be pedantic
        bb.note(pn + ": Recipe file does not have license file information.")
        return lic_files_paths

    for url in lic_files.split():
        try:
            (type, host, path, user, pswd, parm) = bb.fetch.decodeurl(url)
        except bb.fetch.MalformedUrl:
            raise bb.build.FuncFailed("%s: LIC_FILES_CHKSUM contains an invalid URL:  %s" % (d.getVar('PF', True), url))
        # We want the license filename and path
        srclicfile = os.path.join(srcdir, path)
        lic_files_paths.append((os.path.basename(path), srclicfile))

    v = FindVisitor()
    try:
        v.visit_string(license_types)
    except oe.license.InvalidLicense as exc:
        bb.fatal('%s: %s' % (d.getVar('PF', True), exc))
    except SyntaxError:
        bb.warn("%s: Failed to parse it's LICENSE field." % (d.getVar('PF', True)))

    return lic_files_paths

def return_spdx(d, license):
    """
    This function returns the spdx mapping of a license if it exists.
     """
    return d.getVarFlag('SPDXLICENSEMAP', license, True)

def canonical_license(d, license):
    """
    Return the canonical (SPDX) form of the license if available (so GPLv3
    becomes GPL-3.0), for the license named 'X+', return canonical form of
    'X' if availabel and the tailing '+' (so GPLv3+ becomes GPL-3.0+), 
    or the passed license if there is no canonical form.
    """
    lic = d.getVarFlag('SPDXLICENSEMAP', license, True) or ""
    if not lic and license.endswith('+'):
        lic = d.getVarFlag('SPDXLICENSEMAP', license.rstrip('+'), True)
        if lic:
            lic += '+'
    return lic or license

def expand_wildcard_licenses(d, wildcard_licenses):
    """
    Return actual spdx format license names if wildcard used. We expand
    wildcards from SPDXLICENSEMAP flags and SRC_DISTRIBUTE_LICENSES values.
    """
    import fnmatch
    licenses = []
    spdxmapkeys = d.getVarFlags('SPDXLICENSEMAP').keys()
    for wld_lic in wildcard_licenses:
        spdxflags = fnmatch.filter(spdxmapkeys, wld_lic)
        licenses += [d.getVarFlag('SPDXLICENSEMAP', flag) for flag in spdxflags]

    spdx_lics = (d.getVar('SRC_DISTRIBUTE_LICENSES') or '').split()
    for wld_lic in wildcard_licenses:
        licenses += fnmatch.filter(spdx_lics, wld_lic)

    licenses = list(set(licenses))
    return licenses

def incompatible_license_contains(license, truevalue, falsevalue, d):
    license = canonical_license(d, license)
    bad_licenses = (d.getVar('INCOMPATIBLE_LICENSE', True) or "").split()
    bad_licenses = expand_wildcard_licenses(d, bad_licenses)
    return truevalue if license in bad_licenses else falsevalue

def incompatible_license(d, dont_want_licenses, package=None):
    """
    This function checks if a recipe has only incompatible licenses. It also
    take into consideration 'or' operand.  dont_want_licenses should be passed
    as canonical (SPDX) names.
    """
    import oe.license
    license = d.getVar("LICENSE_%s" % package, True) if package else None
    if not license:
        license = d.getVar('LICENSE', True)

    # Handles an "or" or two license sets provided by
    # flattened_licenses(), pick one that works if possible.
    def choose_lic_set(a, b):
        return a if all(oe.license.license_ok(lic, dont_want_licenses) \
		 for lic in a) else b

    try:
        licenses = oe.license.flattened_licenses(license, choose_lic_set)
    except oe.license.LicenseError as exc:
        bb.fatal('%s: %s' % (d.getVar('P', True), exc))
    return any(not oe.license.license_ok(canonical_license(d, l), \
		dont_want_licenses) for l in licenses)

def check_license_flags(d):
    """
    This function checks if a recipe has any LICENSE_FLAGS that
    aren't whitelisted.

    If it does, it returns the first LICENSE_FLAGS item missing from the
    whitelist, or all of the LICENSE_FLAGS if there is no whitelist.

    If everything is is properly whitelisted, it returns None.
    """

    def license_flag_matches(flag, whitelist, pn):
        """
        Return True if flag matches something in whitelist, None if not.

        Before we test a flag against the whitelist, we append _${PN}
        to it.  We then try to match that string against the
        whitelist.  This covers the normal case, where we expect
        LICENSE_FLAGS to be a simple string like 'commercial', which
        the user typically matches exactly in the whitelist by
        explicitly appending the package name e.g 'commercial_foo'.
        If we fail the match however, we then split the flag across
        '_' and append each fragment and test until we either match or
        run out of fragments.
        """
        flag_pn = ("%s_%s" % (flag, pn))
        for candidate in whitelist:
            if flag_pn == candidate:
                    return True

        flag_cur = ""
        flagments = flag_pn.split("_")
        flagments.pop() # we've already tested the full string
        for flagment in flagments:
            if flag_cur:
                flag_cur += "_"
            flag_cur += flagment
            for candidate in whitelist:
                if flag_cur == candidate:
                    return True
        return False

    def all_license_flags_match(license_flags, whitelist):
        """ Return first unmatched flag, None if all flags match """
        pn = d.getVar('PN', True)
        split_whitelist = whitelist.split()
        for flag in license_flags.split():
            if not license_flag_matches(flag, split_whitelist, pn):
                return flag
        return None

    license_flags = d.getVar('LICENSE_FLAGS', True)
    if license_flags:
        whitelist = d.getVar('LICENSE_FLAGS_WHITELIST', True)
        if not whitelist:
            return license_flags
        unmatched_flag = all_license_flags_match(license_flags, whitelist)
        if unmatched_flag:
            return unmatched_flag
    return None

def check_license_format(d):
    """
    This function checks if LICENSE is well defined,
        Validate operators in LICENSES.
        No spaces are allowed between LICENSES.
    """
    pn = d.getVar('PN', True)
    licenses = d.getVar('LICENSE', True)
    from oe.license import license_operator, license_operator_chars, license_pattern

    elements = filter(lambda x: x.strip(), license_operator.split(licenses))
    for pos, element in enumerate(elements):
        if license_pattern.match(element):
            if pos > 0 and license_pattern.match(elements[pos - 1]):
                bb.warn('%s: LICENSE value "%s" has an invalid format - license names ' \
                        'must be separated by the following characters to indicate ' \
                        'the license selection: %s' %
                        (pn, licenses, license_operator_chars))
        elif not license_operator.match(element):
            bb.warn('%s: LICENSE value "%s" has an invalid separator "%s" that is not ' \
                    'in the valid list of separators (%s)' %
                    (pn, licenses, element, license_operator_chars))

SSTATETASKS += "do_populate_lic"
do_populate_lic[sstate-inputdirs] = "${LICSSTATEDIR}"
do_populate_lic[sstate-outputdirs] = "${LICENSE_DIRECTORY}/"

ROOTFS_POSTPROCESS_COMMAND_prepend = "write_package_manifest; license_create_manifest; "

do_populate_lic_setscene[dirs] = "${LICSSTATEDIR}/${PN}"
do_populate_lic_setscene[cleandirs] = "${LICSSTATEDIR}"
python do_populate_lic_setscene () {
    sstate_setscene(d)
}
addtask do_populate_lic_setscene
