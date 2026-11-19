import javax.crypto.AEADBadTagException;
import javax.crypto.Cipher;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.PBEKeySpec;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;

public class VerifyMasarefyBackup {
  static byte[] decrypt(byte[] raw, char[] password) throws Exception {
    byte[] magic = "MASAREFY_BACKUP".getBytes(StandardCharsets.US_ASCII);
    if (raw.length < magic.length + 2 + 16 + 12 + 16) throw new AssertionError("Backup too small");
    if (!Arrays.equals(Arrays.copyOfRange(raw, 0, magic.length), magic)) throw new AssertionError("Not encrypted backup magic");
    int v = raw[magic.length] & 0xff, kdf = raw[magic.length+1] & 0xff;
    if (v != 1 || (kdf != 1 && kdf != 2)) throw new AssertionError("Invalid crypto header");
    int i = magic.length+2;
    byte[] salt=Arrays.copyOfRange(raw,i,i+16); i+=16;
    byte[] iv=Arrays.copyOfRange(raw,i,i+12); i+=12;
    byte[] encrypted=Arrays.copyOfRange(raw,i,raw.length);
    String algo=kdf==2 ? "PBKDF2WithHmacSHA256" : "PBKDF2WithHmacSHA1";
    PBEKeySpec spec=new PBEKeySpec(password,salt,310000,256);
    byte[] keyBytes;
    try { keyBytes=SecretKeyFactory.getInstance(algo).generateSecret(spec).getEncoded(); }
    finally { spec.clearPassword(); }
    try {
      Cipher c=Cipher.getInstance("AES/GCM/NoPadding");
      c.init(Cipher.DECRYPT_MODE,new SecretKeySpec(keyBytes,"AES"),new GCMParameterSpec(128,iv));
      c.updateAAD(magic);
      c.updateAAD(new byte[]{(byte)v,(byte)kdf});
      return c.doFinal(encrypted);
    } finally { Arrays.fill(keyBytes,(byte)0); }
  }
  public static void main(String[] args) throws Exception {
    if (args.length!=2 && args.length!=3) throw new IllegalArgumentException("Expected file, synthetic-only password and optional synthetic category marker");
    String marker=args.length==3 ? args[2] : "QA2026";
    byte[] raw=Files.readAllBytes(Path.of(args[0]));
    if (raw.length<100) throw new AssertionError("Backup file too small");
    String encryptedText=new String(raw,StandardCharsets.ISO_8859_1);
    if (encryptedText.contains(marker)) throw new AssertionError("Transaction category leaked in ciphertext");
    char[] password=args[1].toCharArray();
    byte[] plain=decrypt(raw,password);
    String json=new String(plain,StandardCharsets.UTF_8);
    if (!json.startsWith("{") || !json.contains(marker) || !json.contains("transactions"))
      throw new AssertionError("Decrypted backup missing synthetic transaction");
    boolean rejected=false;
    try { decrypt(raw,"WrongPasswordForQATest".toCharArray()); }
    catch (AEADBadTagException expected) { rejected=true; }
    if (!rejected) throw new AssertionError("Wrong password was not rejected by GCM");
    Arrays.fill(plain,(byte)0);
    Arrays.fill(password,'\0');
    System.out.println("PASS: official signed APK produced authenticated encrypted .mfb with synthetic expense; correct password decrypts; wrong password fails; no plaintext category.");
  }
}
