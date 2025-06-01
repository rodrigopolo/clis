# Rodrigo Polo's CLIs

Multiple command line utilities and scripts for the daily use.

* [Local Bin](./bin)
* [360](./360)

## Dependencies

### Homebrew
You'll need to install Homebrew, the free and open-source software package
management system for macOS, installations instrucctions are available in the
official Homebrew site: https://brew.sh

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

## CLIs Installation
Cloning the repo into your home folder
```sh
cd
git clone https://github.com/rodrigopolo/clis.git
```

Add the `~/clis/bin` to the shell
```sh
echo '[[ -d $HOME/clis/bin ]] && export PATH="$HOME/clis/bin:$PATH"' >> ~/.zshrc
```

Execute scripts in the `360` directory
```sh
~/clis/360/toequirectangular.sh
```

Update the scripts
```sh
cd ~/clis
git pull
```

### For the scripts in the `bin` folder

Install the following brew formulas
```sh
brew install wget mediainfo exiftool ffmpeg yt-dlp aria2c
```

### Python
Python is required for the `srt` `Kubi.sh` scripts

A quick and reliable way to have Python installed is `pyenv`, a Python version
manager that lets you easily install, switch between, and manage multiple Python
versions, `pyenv` needs to be installed with Homebrew:

```sh
brew install pyenv
```

After installing `pyenv` it will show some commands to add `pyenv` to the shell:
```sh
echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.zshrc
echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.zshrc
echo 'eval "$(pyenv init - zsh)"' >> ~/.zshrc
```

These commands adds this to the `.zshrc` file the `pyenv` initialization, this
could vary from system to system:
```
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - zsh)"
```

Now that we have `pyenv` installed, we have to install a `Python` version and
make it available systemwide:
```sh
pyenv install 3.10.4
pyenv global 3.10.4
```
