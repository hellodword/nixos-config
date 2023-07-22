{ persistPath, ... }:

{
  # !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  # DO NOT USE home-manager persistence!!! IT'S BUGGY
  # e.g. ulimit won't respect the global settings
  # e.g. volume in docker, ulimit -Hn and ulimt -Sn is ok, but the real ulimit will be 1024
  environment.persistence = {
    "${persistPath}" = {
      users."ubuntu".directories = [
        # 临时/只读的项目
        "dev/park"

        # 个人项目，按照大类别分类
        "dev/workspace"

        # 临时验证项目，playground 性质
        "dev/playground"

        # 笔记、文档类
        "dev/note"

        # 一些备份文件
        "backups"
      ];
    };
  };
}
