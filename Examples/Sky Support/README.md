Import the .cell file in Cell with Plugins → Import. Select the plugin and allow scripts and programs to run the two DNS checks. The checks query public domains and do not access Steam or Sky account data. The Windows check uses Winsock in the selected layer. The shell check uses the Mac resolver and records its result in the Wine prefix.

The launch hook and key mappings are optional. Enable them in Options. The hook runs for a game launched by Cell. Existing Wine processes need to be relaunched before key mappings apply. The C source is included so developers can inspect and adapt the Windows example.

To carry an existing Sky profile into the Steam edition, open the profile on mobile using its linked account, then link Steam under Settings → Account. On PC, launch Sky from that Steam account. See the developer’s [PC and Steam account guide](https://thatgamecompany.helpshift.com/hc/en/19-sky-pc-steam/faq/1171-how-do-i-save-my-progress/).

To distribute your own plugin, edit plugin.json or use Cell’s plugin editor. Save it with your own package ID and export it as a .cell file. The manifest can include an HTTPS updateURL pointing at a package with the same ID.
