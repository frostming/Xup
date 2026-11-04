.PHONY: build cli app run install install-cli uninstall-cli test clean

APP = build/Xup.app
CLI_LINK = $(HOME)/.local/bin/xup

build:
	swift build --product Xup

cli:
	swift build --product xup-cli

app:
	./scripts/build-app.sh

run: app
	open $(APP)

install: app install-cli
	rm -rf /Applications/Xup.app
	cp -R $(APP) /Applications/Xup.app
	@echo "已安装到 /Applications/Xup.app"

# 把 App 内置的 CLI 软链到 ~/.local/bin/xup（目录不存在则创建）
install-cli:
	mkdir -p $(dir $(CLI_LINK))
	ln -sfn /Applications/Xup.app/Contents/Helpers/xup $(CLI_LINK)
	@echo "已创建软链 $(CLI_LINK) -> /Applications/Xup.app/Contents/Helpers/xup"
	@case ":$$PATH:" in *":$(dir $(CLI_LINK))"*|*":$(HOME)/.local/bin:"*) ;; *) echo "提示：$(dir $(CLI_LINK)) 不在 PATH 中，请加入 shell 配置";; esac

uninstall-cli:
	rm -f $(CLI_LINK)
	@echo "已移除 $(CLI_LINK)"

test:
	swift test

clean:
	rm -rf .build build
