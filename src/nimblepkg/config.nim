# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import parsecfg, streams, strutils, os, tables, uri

import common, cli

type
  Config* = object
    nimbleDir*: string
    chcp*: bool # Whether to change the code page in .cmd files on Win.
    packageLists*: Table[string, PackageList] ## Names -> packages.json files
    cloneUsingHttps*: bool # Whether to replace git:// for https://
    httpProxy*: Uri # Proxy for package list downloads.
    urlMappings*: Table[string, string] ## URLs to new URLS

  PackageList* = object
    name*: string
    urls*: seq[string]
    path*: string

const 
  cachedPkgListName* = "nimblecached"

proc initConfig(): Config =
  result.nimbleDir = getHomeDir() / ".nimble"
  result.httpProxy = initUri()
  result.chcp = true
  result.cloneUsingHttps = true
  result.urlMappings = initTable[string, string]()
  result.packageLists["official"] = PackageList(name: "Official", urls: @[
    "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
    "https://nim-lang.org/nimble/packages.json"
  ])
  result.packageLists[cachedPkgListName] = PackageList(name: "NimbleCached", urls: @[])

proc clear(pkgList: var PackageList) =
  pkgList.name = ""
  pkgList.urls = @[]
  pkgList.path = ""


proc endSection(config: var Config,
                currentSection: string,
                currentPackageList: var PackageList,
                currentUrlRedirect: var tuple[origin: string, target: string]
) =
  case currentSection
  of "packagelist":
    if currentPackageList.urls.len == 0 and currentPackageList.path == "":
      raise nimbleError("Package list '$1' requires either url or path" % currentPackageList.name)
    if currentPackageList.urls.len > 0 and currentPackageList.path != "":
      raise nimbleError("Attempted to specify `url` and `path` for the same package list '$1'" % currentPackageList.name)
    if currentPackageList.name.len > 0:
      config.packageLists[currentPackageList.name.normalize] = currentPackageList
  of "urlredirect":
    if currentUrlRedirect.origin.len > 0:
      config.urlMappings[currentUrlRedirect.origin] = currentUrlRedirect.target
  else:
    discard

proc parseConfig*(): Config =
  result = initConfig()
  var confFile = getConfigDir() / "nimble" / "nimble.ini"

  var f = newFileStream(confFile, fmRead)
  if f != nil:
    display("Reading", "config file at " & confFile, priority = LowPriority)
    var p: CfgParser
    open(p, f, confFile)
    var currentSection = ""
    var currentPackageList: PackageList
    var currentUrlRedirect: tuple[origin: string, target: string]
    while true:
      var e = next(p)
      case e.kind
      of cfgEof:
        result.endSection(currentSection, currentPackageList, currentUrlRedirect)
        break
      of cfgSectionStart:
        result.endSection(currentSection, currentPackageList, currentUrlRedirect)
        currentSection = e.section.normalize()
        case currentSection
        of "packagelist":
          currentPackageList.clear()
        of "urlredirect":
          currentUrlRedirect = ("", "")
        else:
          raise nimbleError("Unable to parse config file:" &
                             " Unknown section: " & e.key)
      of cfgKeyValuePair, cfgOption:
        case e.key.normalize
        of "nimbledir":
          # Ensure we don't restore the deprecated nimble dir.
          if e.value != getHomeDir() / ".babel":
            result.nimbleDir = e.value
        of "chcp":
          result.chcp = parseBool(e.value)
        of "cloneusinghttps":
          result.cloneUsingHttps = parseBool(e.value)
        of "httpproxy":
          result.httpProxy = parseUri(e.value)
        of "name":
          case currentSection
          of "packagelist":
            currentPackageList.name = e.value
          else: assert false
        of "url":
          case currentSection
          of "packagelist":
            currentPackageList.urls.add(e.value)
          else: assert false
        of "origin":
          case currentSection
          of "urlredirect":
            currentUrlRedirect.origin = e.value
          else: assert false
        of "target":
          case currentSection
          of "urlredirect":
            currentUrlRedirect.target = e.value
          else: assert false
        of "path":
          case currentSection
          of "packagelist":
            if currentPackageList.path != "":
              raise nimbleError("Attempted to specify more than one `path` for the same package list.")
            else:
              currentPackageList.path = e.value
          else: assert false
        of "nimlibprefix":
          # Not relevant anymore but leaving in for legacy ini files
          discard
        else:
          raise nimbleError("Unable to parse config file:" &
                                     " Unknown key: " & e.key)
      of cfgError:
        raise nimbleError("Unable to parse config file: " & e.msg)
    close(p)

  echo "parseConfig: ", result