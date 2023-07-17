# kiosk-user
A debian package to simplify the task of creating a 'kiosk' from a standard X windows application.

## Preface
With the rise in the availabilty of SBCs such as the Raspberry Pi, more and more of these are being used to provide kiosk's, that is machines dedicated to a single purpose such as 
information displays. This package simplifies the process of wrapping an application in a setup so that it's the primary task of the machine.

### Detail
The package performs several main functions.
1. Asks for a user to run the application as, and if that user doesn't exist creates one.
2. Swaps systemd's default target to multi-user, and configures tty1 to autologin that user.
3. Creates a '.xinit' file, starting among other things matchbox window manager and the required application.
4. Adds 'startx', if needed, to the user's '.bashrc' file to run xinit and therefore the .xinit file

## Usage
To use this package, download to a suitable location on the machine and then as root or using sudo:

```
dpkg --install kiosk-user_0.2_all.deb
```

There are several option screens in the package, not all will be displayed necessarily when you install, depending on your debconf priority. If you wish to access these sections, or change any of the previously set values run:

```
dpkg-reconfigure kiosk-user
```

<img src="packages/pics/kiosk-user/dialog_username.png" height="20%" width="20%" align="right">
Set the user to run the application as. This can be an existing user, but it is recommended to use a new user here.<br/><br/>
This screen is only accessible on installation, you can't change the user with the package installed. To change the user, uninstall the package and reinstall it.
<br clear="right"/><br/>
<img src="packages/pics/kiosk-user/dialog_app_path.png" height="20%" width="20%" align="right">
Enter the full path to the application, it will be checked and rejected if the file is not executable. E.g.

```
/usr/bin/firefox
```

<br clear="right"/><br/>
<img src="packages/pics/kiosk-user/dialog_app_zrgs.png" height="20%" width="20%" align="right">
Arguments to pass to the application, obviously these are application specific. Following the previous example:

```
--kiosk
```

Don't append '&' to run the application in the background, it will break things.
<br clear="right"/><br/>

### Use dpkg-reconfigure to access these

<img src="packages/pics/kiosk-user/dialog_screen_orientation.png" height="20%" width="20%" align="right">
Uses xrandr to set screen orientation.
<br clear="right"/><br/>
<img src="packages/pics/kiosk-user/dialog_options.png" height="20%" width="20%" align="right">
Various additional options, the defaults are usually what you want.
<br clear="right"/><br/>
  
## Todo
* SysVinit support
* Virtual keyboard support
