import 'package:packagekit/packagekit.dart';
import 'package:software/l10n/l10n.dart';

extension PackageKitFilterX on PackageKitFilter {
  String localize(AppLocalizations l10n) {
    switch (this) {
      default:
        return name;
    }
  }
}
