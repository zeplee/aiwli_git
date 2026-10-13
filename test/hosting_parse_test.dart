import 'package:flutter_test/flutter_test.dart';
import 'package:aiwli_git/core/hosting_api.dart';

void main() {
  group('parseGithubRepos', () {
    test('maps the fields aiwli uses and skips malformed entries', () {
      const body = '''
[
  {
    "name": "demo",
    "full_name": "alice/demo",
    "description": "test repo",
    "updated_at": "2026-09-30T10:00:00Z",
    "private": true,
    "clone_url": "https://github.com/alice/demo.git",
    "ssh_url": "git@github.com:alice/demo.git",
    "default_branch": "main"
  },
  {"full_name": "ghost"},
  {"name": "minimal", "clone_url": "https://github.com/alice/minimal.git"}
]
''';
      final repos = parseGithubRepos(body);
      expect(repos.length, 2);
      final first = repos[0];
      expect(first.name, 'demo');
      expect(first.fullName, 'alice/demo');
      expect(first.isPrivate, isTrue);
      expect(first.httpsUrl, 'https://github.com/alice/demo.git');
      expect(first.sshUrl, 'git@github.com:alice/demo.git');
      expect(first.defaultBranch, 'main');
      expect(repos[1].name, 'minimal');
      expect(repos[1].description, isNull);
    });

    test('empty list', () {
      expect(parseGithubRepos('[]'), isEmpty);
    });
  });

  group('parseGitlabRepos (GitLab + Codeup)', () {
    test('maps GitLab project fields', () {
      const body = '''
[
  {
    "name": "backend",
    "path_with_namespace": "team/backend",
    "description": "svc",
    "last_activity_at": "2026-10-01T08:00:00Z",
    "visibility": "private",
    "http_url_to_repo": "https://gitlab.com/team/backend.git",
    "ssh_url_to_repo": "git@gitlab.com:team/backend.git",
    "default_branch": "master"
  }
]
''';
      final repos = parseGitlabRepos(body);
      expect(repos.length, 1);
      expect(repos[0].fullName, 'team/backend');
      expect(repos[0].isPrivate, isTrue);
      expect(repos[0].updatedAt, '2026-10-01T08:00:00Z');
      expect(repos[0].defaultBranch, 'master');
    });
  });

  group('parseWhoami', () {
    test('github login / gitlab username', () {
      expect(parseWhoami('github', '{"login":"alice"}'), 'alice');
      expect(parseWhoami('gitlab', '{"username":"bob"}'), 'bob');
      expect(parseWhoami('github', '{}'), isNull);
    });
  });

  group('云效 OpenAPI 解析（防御式）', () {
    test('whoami：name / username / 嵌套 result 都能取', () {
      expect(parseCodeupWhoami('{"name":"Carol"}'), 'Carol');
      expect(parseCodeupWhoami('{"username":"carol"}'), 'carol');
      expect(parseCodeupWhoami('{"result":{"displayName":"Lee"}}'), 'Lee');
      expect(parseCodeupWhoami('{"id":12345}'), '12345');
      expect(parseCodeupWhoami('{"foo":1}'), isNull);
    });

    test('仓库列表：裸数组与 {result:[...]} 两种封装', () {
      const item = '{"id":1,"name":"demo","path":"group/demo",'
          '"visibility":"private","httpUrl":"https://codeup.aliyun.com/g/demo.git",'
          '"sshUrl":"git@codeup.aliyun.com:g/demo.git","lastActivityAt":"2026-10-01T08:00:00Z"}';
      final bare = parseCodeupRepos('[$item]');
      expect(bare.length, 1);
      expect(bare[0].name, 'demo');
      expect(bare[0].fullName, 'group/demo');
      expect(bare[0].isPrivate, isTrue);
      expect(bare[0].sshUrl, 'git@codeup.aliyun.com:g/demo.git');
      expect(bare[0].updatedAt, '2026-10-01T08:00:00Z');

      final wrapped = parseCodeupRepos('{"result":[$item],"total":1}');
      expect(wrapped.length, 1);
      expect(wrapped[0].name, 'demo');
      expect(parseCodeupRepos('{"result":[]}'), isEmpty);
    });

    test('visibility=public 判为非私有', () {
      final r = parseCodeupRepos(
        '[{"name":"pub","path":"p","visibility":"public"}]',
      );
      expect(r[0].isPrivate, isFalse);
    });

    test('新建仓库响应：裸对象与 {result:{...}}', () {
      expect(parseCodeupCreated('{"name":"n","path":"g/n"}')?.name, 'n');
      expect(
        parseCodeupCreated('{"result":{"name":"n","path":"g/n"}}')?.fullName,
        'g/n',
      );
      expect(parseCodeupCreated('[]'), isNull);
    });

    test('非 JSON 响应（登录页 HTML）给出人话提示', () {
      final hint = nonJsonHint('连接测试', '<!DOCTYPE html>\n<html lang="zh">…');
      expect(hint, contains('不是 JSON'));
      expect(hint, contains('<!DOCTYPE html>'));
      expect(hint, contains('连接测试'));
    });
  });

  group('request builders', () {
    test('github headers carry auth + api version', () {
      final h = githubHeaders('tok');
      expect(h['Authorization'], 'Bearer tok');
      expect(h['X-GitHub-Api-Version'], '2022-11-28');
      expect(h['User-Agent'], 'AiwliGit');
    });

    test('gitlab headers use PRIVATE-TOKEN', () {
      expect(gitlabHeaders('tok')['PRIVATE-TOKEN'], 'tok');
    });

    test('云效 headers 用 x-yunxiao-token（不是 PRIVATE-TOKEN）', () {
      final h = codeupHeaders('tok');
      expect(h['x-yunxiao-token'], 'tok');
      expect(h.containsKey('PRIVATE-TOKEN'), isFalse);
    });

    test('gitlab repos uri embeds org', () {
      final uri = gitlabReposUri('gitlab.com', org: '42');
      expect(uri.host, 'gitlab.com');
      expect(uri.path, '/api/v4/projects');
      expect(uri.queryParameters['organizationId'], '42');
      expect(uri.queryParameters['membership'], 'true');
      expect(uri.queryParameters['per_page'], '100');
    });

    test('云效 repos uri 走 openapi-rdc 且带组织 ID', () {
      final uri = codeupReposUri('42');
      expect(uri.host, 'openapi-rdc.aliyuncs.com');
      expect(uri.path, '/oapi/v1/codeup/organizations/42/repositories');
      expect(uri.queryParameters['perPage'], '100');
      expect(uri.queryParameters['orderBy'], 'last_activity_at');
    });

    test('云效不再指向 codeup.aliyun.com/api/v4（网页会话端点）', () {
      expect(codeupWhoamiUri().host, 'openapi-rdc.aliyuncs.com');
      expect(codeupWhoamiUri().path, '/oapi/v1/platform/user');
      expect(codeupCreateRepoUri('42').host, 'openapi-rdc.aliyuncs.com');
      expect(codeupCreateRepoUri('42').path,
          '/oapi/v1/codeup/organizations/42/repositories');
    });

    test('whoami uri per provider', () {
      expect(whoamiUri('github', '').toString(), 'https://api.github.com/user');
      expect(
        whoamiUri('gitlab', 'gitlab.com').toString(),
        'https://gitlab.com/api/v4/user',
      );
    });
  });

  group('parseDeviceCode', () {
    test('defaults', () {
      final dc = parseDeviceCode({
        'device_code': 'DC',
        'user_code': 'ABCD-1234',
        'verification_uri': 'https://github.com/login/device',
        'expires_in': 900,
        'interval': 5,
      });
      expect(dc.deviceCode, 'DC');
      expect(dc.userCode, 'ABCD-1234');
      expect(dc.interval, 5);
    });

    test('missing fields fall back to safe defaults', () {
      final dc = parseDeviceCode({});
      expect(dc.deviceCode, isEmpty);
      expect(dc.verificationUri, 'https://github.com/login/device');
      expect(dc.interval, 5);
    });
  });

  group('account helpers', () {
    test('provider/host/token/org extraction with defaults', () {
      final a = <String, Object?>{
        'provider': 'github',
        'label': 'me',
        'pass': 't',
      };
      expect(accountProvider(a), 'github');
      expect(accountHost(a), 'github.com');
      expect(accountToken(a), 't');
      expect(accountOrg(a), isNull);
      expect(supportsCloudImport(a), isTrue);
      final generic = <String, Object?>{'provider': 'generic', 'host': 'x'};
      expect(supportsCloudImport(generic), isFalse);
      final noToken = <String, Object?>{'provider': 'github'};
      expect(supportsCloudImport(noToken), isTrue);
      expect(accountToken(noToken), isNull);
    });
  });

  group('createRepoBody', () {
    test('GitHub 用 private 字段', () {
      expect(createRepoBody('github', 'demo', true), '{"name":"demo","private":true}');
      expect(
        createRepoBody('github', 'demo', false),
        '{"name":"demo","private":false}',
      );
    });
    test('GitLab 用 visibility 字段', () {
      expect(
        createRepoBody('gitlab', 'demo', true),
        '{"name":"demo","visibility":"private"}',
      );
    });
    test('云效新建仓库体（name+path+visibility）', () {
      expect(
        codeupCreateRepoBody('demo', true),
        '{"name":"demo","path":"demo","visibility":"private"}',
      );
      expect(
        codeupCreateRepoBody('demo', false),
        '{"name":"demo","path":"demo","visibility":"public"}',
      );
    });
  });

  group('createRepoUri', () {
    test('GitHub 走 /user/repos，GitLab 走 /api/v4/projects', () {
      expect(
        createRepoUri('github', '').toString(),
        'https://api.github.com/user/repos',
      );
      expect(
        createRepoUri('gitlab', 'gitlab.com').toString(),
        'https://gitlab.com/api/v4/projects',
      );
    });
  });

  group('isFork 解析', () {
    test('GitHub fork 字段', () {
      final repos = parseGithubRepos(
        '[{"name":"demo","fork":true,"clone_url":"https://github.com/a/demo.git"},'
        '{"name":"mine","fork":false,"clone_url":"https://github.com/a/mine.git"}]',
      );
      expect(repos[0].isFork, isTrue);
      expect(repos[1].isFork, isFalse);
    });
    test('GitLab/Codeup forked_from_project 存在即 fork', () {
      final repos = parseGitlabRepos(
        '[{"name":"demo","forked_from_project":{"id":1},'
        '"http_url_to_repo":"https://x.git"},'
        '{"name":"mine","http_url_to_repo":"https://x.git"}]',
      );
      expect(repos[0].isFork, isTrue);
      expect(repos[1].isFork, isFalse);
    });
    test('默认非 fork', () {
      final r = parseGithubRepo({'name': 'demo'});
      expect(r!.isFork, isFalse);
    });
  });

  group('星标端点', () {
    test('GitHub 星标走 /user/starred', () {
      expect(
        githubStarredUri().toString(),
        'https://api.github.com/user/starred?per_page=100&sort=updated',
      );
    });
    test('GitLab/Codeup 星标走 projects?starred=true', () {
      expect(
        gitlabStarredUri('codeup.aliyun.com', org: '666')
            .toString(),
        'https://codeup.aliyun.com/api/v4/projects'
        '?starred=true&order_by=last_activity_at&per_page=100&organizationId=666',
      );
    });
  });

  group('parseCreatedRepo', () {
    test('解析 GitHub 创建响应', () {
      final r = parseCreatedRepo(
        'github',
        '{"name":"demo","full_name":"alice/demo","private":true,'
        '"clone_url":"https://github.com/alice/demo.git"}',
      );
      expect(r, isNotNull);
      expect(r!.fullName, 'alice/demo');
      expect(r.httpsUrl, 'https://github.com/alice/demo.git');
    });
    test('解析 GitLab/Codeup 创建响应', () {
      final r = parseCreatedRepo(
        'codeup',
        '{"name":"demo","path_with_namespace":"org1/demo",'
        '"visibility":"private","http_url_to_repo":"https://codeup.aliyun.com/org1/demo.git"}',
      );
      expect(r, isNotNull);
      expect(r!.fullName, 'org1/demo');
      expect(r.isPrivate, isTrue);
      expect(r.httpsUrl, 'https://codeup.aliyun.com/org1/demo.git');
    });
    test('非对象响应返回 null', () {
      expect(parseCreatedRepo('github', '"ok"'), isNull);
    });
  });
}
