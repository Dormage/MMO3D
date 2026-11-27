using UnityEngine;

namespace DynamicRagdoll
{
    public class FootDetect : MonoBehaviour
    {
        public bool isGrounded = false;

        public Transform RefObj;
        public int upAxis;
        private void OnCollisionEnter(Collision collision)
        {
            isGrounded = false;

            foreach (ContactPoint contact in collision.contacts)
            {
                float dotProduct = Vector3.Dot(contact.normal, RefObj.GetWorldDir(upAxis));

                if (dotProduct > 0.3f)
                {
                    isGrounded = true;
                    break;
                }
            }

        }
        private void OnCollisionStay(Collision collision)
        {

        }
        private void OnCollisionExit(Collision collision)
        {

            isGrounded = false;

        }

    }
}

