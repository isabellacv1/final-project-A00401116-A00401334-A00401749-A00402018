// Commit message rules. See docs/CONTRIBUTING.md for the full convention.
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [
      2,
      'always',
      ['feat', 'fix', 'perf', 'refactor', 'docs', 'test', 'build', 'ci', 'chore', 'style', 'revert'],
    ],
    'scope-case': [2, 'always', 'lower-case'],
    'scope-enum': [
      1,
      'always',
      [
        'auth', 'identity', 'promotion', 'form', 'gateway', 'notification', 'file', 'dashboard',
        'mobile',
        'ci', 'infra', 'deploy', 'k8s', 'observability', 'security',
        'docs', 'deps', 'tests',
      ],
    ],
    'subject-case': [2, 'always', 'lower-case'],
    'subject-full-stop': [2, 'never', '.'],
    'header-max-length': [2, 'always', 100],
  },
};
