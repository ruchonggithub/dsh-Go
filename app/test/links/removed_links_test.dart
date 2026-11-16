import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/links/removed_links.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/relay_server_entry.dart';
import 'package:dsh_app/update/update_config.dart';

/// The build removes its optional third-party links; these pin that the policy
/// constants and the code paths that read them agree.
void main() {
  group('removed links', () {
    test('this build offers no forum, workshop, project update host or hosted relay', () {
      expect(forumEnabled, isFalse);
      expect(workshopEnabled, isFalse);
      expect(projectUpdateHostsEnabled, isFalse);
      expect(hostedRelayServerEnabled, isFalse);
    });
  });

  group('update sources', () {
    test('ask GitHub and nothing else', () {
      final sources = defaultUpdateSources();

      // The beta channel is what would carry the project's token.
      expect(sources.channel, isNull);

      // No self-hosted feed: every manifest endpoint that remains must be a
      // github.com URL (the API lives on api.github.com), and the API endpoint
      // is GitHub's own.
      expect(sources.feed, isNull);
      for (final endpoint in sources.metadataEndpoints()) {
        expect(
          endpoint.url.host,
          anyOf('github.com', 'api.github.com'),
          reason: 'metadata endpoint ${endpoint.id} leaves GitHub: ${endpoint.url}',
        );
      }

      // Downloads must not go through a mirror of the project's copy either.
      for (final mirror in sources.mirrors) {
        expect(
          mirror.releases,
          isNull,
          reason: 'mirror ${mirror.id} still rewrites to a self-hosted copy',
        );
      }
      expect(sources.mirrors.map((m) => m.id), contains('github'));
    });
  });

  group('hosted relay server', () {
    test('a null selection means no server, not the hosted one', () {
      expect(resolveRelayServer(null), isNull);
      expect(resolveRelayServer('https://self.example.com'), 'https://self.example.com');
    });

    test('a saved hosted address is not treated as the default', () {
      // Another build may have written this entry; it must not be flagged as
      // the special default, because this build offers no such default.
      const entry = RelayServerEntry(origin: defaultRelayServerOrigin);
      expect(entry.isDefault, isFalse);
      // It is still a usable address, so it is not misread as garbage.
      expect(entry.hostLabel, 'dsh.r2049.cn');
    });
  });
}
