"""Exercise a real Tauri/WebKitGTK window against native PTYs and the request CLI.

Start tauri-driver under the same user and XDG_RUNTIME_DIR, then run this file.
"""
import json, os, pathlib, shlex, subprocess, tempfile, time
from selenium import webdriver
from selenium.webdriver.common.options import ArgOptions
from selenium.webdriver.remote.client_config import ClientConfig
from selenium.webdriver.common.by import By
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import Select
from selenium.webdriver.support.ui import WebDriverWait
binary = pathlib.Path(os.environ["AKITTY_DESKTOP_BINARY"]).resolve()
companion = pathlib.Path(os.environ.get("AKITTY_AGENT_BINARY", str(binary.parent / ("akitty-agent.exe" if os.name == "nt" else "akitty-agent")))).resolve()
output = pathlib.Path(os.environ.get("AKITTY_SMOKE_OUTPUT_DIR", "build/linux-smoke"))
output.mkdir(parents=True, exist_ok=True)
workspace = tempfile.TemporaryDirectory(prefix="akitty-ui-smoke-")
class Options(ArgOptions):
    @property
    def default_capabilities(self):
        return {'browserName':'wry','tauri:options':{'application':str(binary)}}
endpoint=os.environ.get('AKITTY_WEBDRIVER_URL', 'http://127.0.0.1:4444')
driver=webdriver.Remote(command_executor=endpoint,options=Options(),client_config=ClientConfig(remote_server_addr=endpoint,timeout=60))
wait=WebDriverWait(driver,15)
try:
    wait.until(lambda d: len(d.find_elements(By.CSS_SELECTOR,'#tabs button'))==1)
    wait.until(lambda d: 'prompt observed' in d.find_element(By.ID,'overview').text)
    assert 'EXPERIMENTAL' in driver.find_element(By.CSS_SELECTOR,'.badge').text
    driver.find_element(By.ID,'enable').click()
    wait.until(lambda d: 'Disable agent' in d.find_element(By.ID,'enable').text)
    env=dict(os.environ)
    cli=[str(companion)]
    listing=json.loads(subprocess.check_output(cli+['list'],env=env))
    pane=listing['data']['panes'][0]['pane']
    marker=pathlib.Path(workspace.name) / 'effect'
    def append_command(path, text):
        return ("[IO.File]::AppendAllText('" + str(path).replace("'", "''") + "','" + text + "')") if os.name == "nt" else f"printf {text} >> {shlex.quote(str(path))}"
    command=append_command(marker, "UI_ACCEPTED")
    caller=subprocess.Popen(cli+['request',pane,command],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    wait.until(lambda d:d.find_element(By.ID,'approval').is_displayed())
    assert driver.find_element(By.ID,'approval-command').text==command
    assert driver.switch_to.active_element.get_attribute('id')=='deny'
    driver.save_screenshot(str(output / 'approval.png'))
    driver.find_element(By.ID,'deny').click()
    out,err=caller.communicate(timeout=10)
    assert caller.returncode==1 and not marker.exists(),(out,err)
    time.sleep(3.2)
    caller=subprocess.Popen(cli+['request',pane,command],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    wait.until(lambda d:d.find_element(By.ID,'approval').is_displayed())
    driver.find_element(By.ID,'allow').click()
    out,err=caller.communicate(timeout=10)
    assert caller.returncode==0,(out,err)
    wait.until(lambda _:marker.exists())
    assert marker.read_text()=='UI_ACCEPTED'
    wait.until(lambda d:'local process' in d.find_element(By.ID,'overview').text)
    driver.save_screenshot(str(output / 'controlled.png'))
    driver.find_element(By.ID,'reclaim').click()
    wait.until(lambda d:'Input owner: human' in d.find_element(By.ID,'overview').text)
    typed=pathlib.Path(workspace.name) / 'typed'
    driver.find_element(By.CSS_SELECTOR,'.terminal canvas').click()
    ActionChains(driver).send_keys(append_command(typed, "TYPED")).send_keys(Keys.ENTER).perform()
    wait.until(lambda _:typed.exists())
    assert typed.read_text()=='TYPED'
    driver.find_element(By.ID,'timeline').click()
    wait.until(lambda d:'command_sha256' in d.find_element(By.ID,'records-text').text)
    assert command not in driver.find_element(By.ID,'records-text').text
    driver.save_screenshot(str(output / 'timeline.png'))
    exported=pathlib.Path(workspace.name) / 'events.jsonl'
    export_path=driver.find_element(By.ID,'export-path')
    export_path.clear(); export_path.send_keys(str(exported))
    driver.find_element(By.ID,'export').click()
    wait.until(lambda d:"Exported retained metadata to" in d.find_element(By.ID,"message").text)
    assert exported.exists()
    assert command not in exported.read_text()
    if os.name != "nt":
        assert exported.stat().st_mode & 0o777 == 0o600
    else:
        script = "$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; $acl=Get-Acl -LiteralPath '" + str(exported).replace("'", "''") + "'; if (@($acl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ne $sid }).Count) { exit 1 }"
        subprocess.run(["powershell.exe", "-NoProfile", "-Command", script], check=True)
    driver.find_element(By.ID,'dismiss').click()
    driver.find_element(By.ID,'close').click()
    wait.until(lambda d:d.find_element(By.ID,'confirm').is_displayed())
    assert driver.switch_to.active_element.get_attribute('id')=='cancel'
    driver.find_element(By.ID,'continue').click()
    wait.until(lambda d:not d.find_elements(By.CSS_SELECTOR,'#tabs button'))
    shell=Select(driver.find_element(By.ID,'shell'))
    zsh=next((option.get_attribute('value') for option in shell.options if option.get_attribute('value').endswith('/zsh')),None)
    if zsh:
        shell.select_by_value(zsh)
        driver.find_element(By.ID,'new').click()
        wait.until(lambda d:len(d.find_elements(By.CSS_SELECTOR,'#tabs button'))==1)
        wait.until(lambda d:'prompt observed' in d.find_element(By.ID,'overview').text)
        driver.find_element(By.ID,'close').click()
        wait.until(lambda d:d.find_element(By.ID,'confirm').is_displayed())
        driver.find_element(By.ID,'continue').click()
        wait.until(lambda d:not d.find_elements(By.CSS_SELECTOR,'#tabs button'))
    print('PASS: real Tauri desktop + native PTY + CLI denial/approval + exact once effect + reclaim + redacted timeline')
finally:
    driver.quit()
    workspace.cleanup()
