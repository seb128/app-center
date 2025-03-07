/*
 * Copyright (C) 2022 Canonical Ltd
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 3 as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

import 'dart:async';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:snapd/snapd.dart';
import 'package:software/services/snap_service.dart';
import 'package:software/snapx.dart';
import 'package:software/app/common/app_model.dart';
import 'package:software/app/common/utils.dart';

class SnapModel extends AppModel {
  SnapModel(
    this._snapService, {
    required this.doneMessage,
    required this.huskSnapName,
    this.online = true,
  })  : _snapChangeInProgress = true,
        _channelToBeInstalled = '';

  Future<void> init() async {
    await _snapService.authorize();
    await _loadSnapChangeInProgress();
    await _loadChange();

    _localSnap = await _findLocalSnap(huskSnapName);
    if (online) {
      _storeSnap = await _findSnapByName(huskSnapName).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          notifyListeners();
          return null;
        },
      );
    }

    _selectableChannels = _fillSelectableChannels(storeSnap: _storeSnap);

    channelToBeInstalled = _determineChannelToBeInstalled(
      storeSnap: _storeSnap,
      snapIsInstalled: snapIsInstalled,
      selectableChannels: selectableChannels,
      trackingChannel: trackingChannel,
    );

    _snapChangesSub = _snapService.snapChangesInserted.listen((_) async {
      await _loadSnapChangeInProgress();
      await _loadChange();
      await _loadPlugs();
      if (!snapChangeInProgress) {
        _localSnap = await _findLocalSnap(huskSnapName);
      }

      notifyListeners();
    });

    await _loadPlugs();
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    await _snapChangesSub?.cancel();
    super.dispose();
  }

  /// The service to handle all snap related actions.
  final SnapService _snapService;

  /// [SnapDClient] does not return information about channels of a [Snap] unless
  /// they are found by name. Thus we instantiate [SnapModel] only with the [huskSnapName]
  /// and load the rest of the information about the snap inside [init].
  final String huskSnapName;

  /// The snap loaded by find inside [init] with given [huskSnapName]
  /// from the snap store. This [Snap] includes all information, but not the installed channel
  /// and not the list of [SnapConnection]s.
  Snap? _storeSnap;

  /// Mainly used for the information about the install [SnapChannel] and
  /// the [SnapConnection]s. It is used as a fallback for some information
  /// if the snap is offline.
  Snap? _localSnap;

  /// Boolean flag to decide if snapd is used offline or online.
  bool online;

  /// Localized string used to after install/refresh/remove to display inside the
  /// desktop notification.
  final String doneMessage;

  /// [StreamSubscription] to listen to snap changes.
  StreamSubscription<bool>? _snapChangesSub;

  /// Apps this snap provides.
  List<SnapApp>? get apps => _localSnap?.apps;

  /// The base snap this snap uses.
  String? get base => _storeSnap?.base ?? _localSnap?.base;

  /// The channel this snap is from, e.g. "stable".
  String? get channel => _localSnap?.channel ?? _storeSnap?.channel;

  /// Map to select a [SnapChannel]
  Map<String, SnapChannel> get selectableChannels => _selectableChannels ?? {};
  Map<String, SnapChannel>? _selectableChannels;

  SnapChannel getSelectableChannel(int i) =>
      selectableChannels.entries.elementAt(i).value;

  String getSelectableChannelName(int i) =>
      selectableChannels.entries.elementAt(i).key;

  /// The [SnapChannel] the snap should be installed from.
  String _channelToBeInstalled;
  String get channelToBeInstalled => _channelToBeInstalled;
  set channelToBeInstalled(String value) {
    if (value == _channelToBeInstalled) return;
    _channelToBeInstalled = value;
    notifyListeners();
  }

  /// Helper getter for the selected [SnapChannel]'s version.
  String get selectedChannelVersion =>
      selectableChannels[channelToBeInstalled] != null
          ? selectableChannels[channelToBeInstalled]!.version
          : '';

  String get selectedChannelReleasedAt =>
      selectableChannels[channelToBeInstalled] != null
          ? DateFormat.yMd(Platform.localeName)
              .format(selectableChannels[channelToBeInstalled]!.releasedAt)
          : '';

  /// Common IDs this snap contains.
  List<String>? get commonIds => _storeSnap?.commonIds ?? _localSnap?.commonIds;

  /// The confinement this snap is using.
  SnapConfinement? get confinement =>
      _storeSnap?.confinement ?? _localSnap?.confinement;

  bool get strict => confinement == SnapConfinement.strict;

  /// Contact URL.
  String? get contact => _storeSnap?.contact ?? _localSnap?.contact;

  /// Multi line description.
  String? get description => _storeSnap?.description ?? _localSnap?.description;

  /// Download size in bytes.
  String get downloadSize =>
      _storeSnap != null && _storeSnap!.downloadSize != null
          ? formatBytes(_storeSnap!.downloadSize!, 2)
          : '';

  /// Helper getter to get the icon url of the [SnapMedia]
  String? get iconUrl => _storeSnap?.iconUrl ?? _localSnap?.iconUrl;

  /// Helper getter to get the screenshot urls of the [SnapMedia]
  List<String>? get screenshotUrls =>
      _storeSnap?.screenshotUrls ?? _localSnap?.screenshotUrls;

  /// Unique ID for this snap.
  String? get id => _storeSnap?.id ?? _localSnap?.id;

  /// The date this snap was installed.
  String get installDate {
    if (_localSnap == null || _localSnap!.installDate == null) return '';

    return DateFormat.yMMMd(Platform.localeName)
        .format(_localSnap!.installDate!);
  }

  /// ISO normed [installDate]
  String get installDateIsoNorm {
    if (_localSnap == null || _localSnap!.installDate == null) return '';

    return DateFormat.yMd(Platform.localeName)
        .add_jms()
        .format(_localSnap!.installDate!.toLocal());
  }

  /// Helper getter to check if the snap has been installed.
  bool get snapIsInstalled =>
      _localSnap != null && _localSnap!.installDate != null;

  /// Installed size in bytes as a formated string.
  String get installedSize {
    return _localSnap != null && _localSnap!.installedSize != null
        ? formatBytes(_localSnap!.installedSize!, 2)
        : '';
  }

  /// Package license.
  String? get license => _storeSnap?.license ?? _localSnap?.license;

  /// The date this snap was installed.
  String get releasedAt {
    if (selectableChannels[channelToBeInstalled] == null) return '';

    return DateFormat.yMMMEd(Platform.localeName)
        .format(selectableChannels[channelToBeInstalled]!.releasedAt);
  }

  /// ISO normed [releasedAt]
  String get releaseAtIsoNorm {
    if (selectableChannels[channelToBeInstalled] == null) return '';

    return DateFormat.yMd(Platform.localeName)
        .add_jms()
        .format(selectableChannels[channelToBeInstalled]!.releasedAt.toLocal());
  }

  /// Media associated with this snap.
  List<SnapMedia>? get media => _storeSnap?.media ?? _localSnap?.media;

  /// Unique name for this snap. Use [title] for displaying.
  String? get name => _storeSnap?.name ?? _localSnap?.name;

  /// Publisher information.
  SnapPublisher? get publisher =>
      _storeSnap?.publisher ?? _localSnap?.publisher;

  /// Revision of this snap.
  String? get revision => _storeSnap?.revision ?? _localSnap?.revision;

  /// URL linking to the snap store page on this snap.
  String? get storeUrl => _storeSnap?.storeUrl ?? _localSnap?.storeUrl;

  /// Single line summary.
  String? get summary => _storeSnap?.summary ?? _localSnap?.summary;

  /// Title of this snap.
  String? get title => _storeSnap?.title ?? _localSnap?.title;

  /// The channel that updates will be installed from, e.g. "stable".
  String? get trackingChannel => _localSnap?.trackingChannel;

  /// Tracks this snap uses.
  List<String>? get tracks => _storeSnap?.tracks;

  /// Type of snap.
  String? get type => _storeSnap?.type ?? _localSnap?.type;

  /// Version of this snap.
  String get version => _localSnap?.version ?? _storeSnap?.version ?? '';

  /// Website URL.
  String? get website => _storeSnap?.website ?? _localSnap?.website;

  /// Checks if the app is started as a snap.
  bool get isSnapEnv => Platform.environment['SNAP']?.isNotEmpty == true;

  /// Helper getter to check if the publisher is verified.
  bool get verified => publisher != null && publisher!.validation == 'verified';

  /// Helper getter to check if the publisher is a starred developer.
  bool get starredDeveloper =>
      publisher != null && publisher!.validation == 'starred';

  /// Helper getter/setters for the change of this snap
  bool _snapChangeInProgress;
  bool get snapChangeInProgress => _snapChangeInProgress;
  set snapChangeInProgress(bool value) {
    if (value == _snapChangeInProgress) return;
    _snapChangeInProgress = value;
    notifyListeners();
  }

  /// Helper getter for showing permissions
  bool get showPermissions =>
      snapIsInstalled && strict && _plugs != null && _plugs!.isNotEmpty;

  /// Asks the [SnapService] if a [SnapDChange] for this snap is in progress
  Future<void> _loadSnapChangeInProgress() async => snapChangeInProgress =
      await _snapService.getSnapChangeInProgress(name: huskSnapName);

  /// The first change in progress for [huskSnapName]
  SnapdChange? _change;
  SnapdChange? get change => _change;
  set change(SnapdChange? value) {
    if (value == _change) return;
    _change = value;
    notifyListeners();
  }

  /// Loads the first change in progress for [huskSnapName] from [SnapService]
  Future<void> _loadChange() async =>
      change = (await _snapService.getSnapChanges(name: huskSnapName));

  Future<Snap?> _findLocalSnap(String huskSnapName) async =>
      _snapService.findLocalSnap(huskSnapName);

  Future<Snap?> _findSnapByName(String name) async =>
      _snapService.findSnapByName(name);

  Future<void> install() async {
    _localSnap = await _snapService.install(
      _storeSnap!,
      channelToBeInstalled,
      doneMessage,
    );
    await _loadPlugs();
    notifyListeners();
  }

  Future<void> remove() async {
    if (_localSnap == null) return;
    _localSnap = await _snapService.remove(_localSnap!, doneMessage);
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_localSnap == null ||
        channelToBeInstalled.isEmpty ||
        selectableChannels[channelToBeInstalled] == null) return;
    _localSnap = await _snapService.refresh(
      snap: _localSnap!,
      message: doneMessage,
      channel: channelToBeInstalled,
      confinement: selectableChannels[channelToBeInstalled]!.confinement,
    );
    await _loadPlugs();
    notifyListeners();
  }

  Map<SnapPlug, bool>? _plugs;
  Map<SnapPlug, bool>? get plugs => _plugs;
  Future<void> _loadPlugs() async {
    if (_localSnap == null) return;
    _plugs?.clear();
    _plugs = await _snapService.loadPlugs(_localSnap!);
    notifyListeners();
  }

  void toggleConnection({
    required String interface,
    required SnapPlug snap,
    required bool value,
  }) {
    _snapService.toggleConnection(
      snapThatWantsAConnection: _localSnap!,
      interface: interface,
      doneMessage: doneMessage,
      value: value,
    );
  }

  void open() {
    if (_localSnap == null && _localSnap!.apps.isEmpty) return;
    Process.start(
      _localSnap!.apps.first.name,
      [],
      mode: ProcessStartMode.detached,
    );
  }

  Map<String, SnapChannel> _fillSelectableChannels({required Snap? storeSnap}) {
    Map<String, SnapChannel> selectableChannels = {};
    if (storeSnap != null && storeSnap.tracks.isNotEmpty) {
      for (var track in storeSnap.tracks) {
        for (var risk in ['stable', 'candidate', 'beta', 'edge']) {
          var name = '$track/$risk';
          var channel = storeSnap.channels[name];
          final channelName = '$track/$risk';
          if (channel != null) {
            selectableChannels.putIfAbsent(channelName, () => channel);
          }
        }
      }
    }
    return selectableChannels;
  }

  String _determineChannelToBeInstalled({
    required Snap? storeSnap,
    required bool snapIsInstalled,
    required Map<String, SnapChannel> selectableChannels,
    required String? trackingChannel,
  }) {
    if (snapIsInstalled && selectableChannels.entries.isNotEmpty) {
      if (trackingChannel != null &&
          selectableChannels.entries
              .where((element) => element.key.contains(trackingChannel))
              .isNotEmpty) {
        return trackingChannel;
      } else {
        return selectableChannels.entries.first.key;
      }
    } else if (storeSnap != null) {
      return selectableChannels.entries.first.key;
    }
    return '';
  }
}
